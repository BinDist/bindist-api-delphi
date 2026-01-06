unit BinDist.AdminV1;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Net.HttpClient,
  System.Net.URLClient, System.DateUtils, System.NetConsts,
  System.Generics.Collections, System.Hash,
  BinDist.Interfaces, BinDist.Exceptions;

type
  THttpVerb = (hvGet, hvPost, hvPatch, hvDelete, hvPut);

  TBinDistAdminV1 = class(TInterfacedObject, IBinDistAdmin)
  private
    FApiKey: string;
    FBaseUrl: string;
    FHttpClient: THTTPClient;

    // Internal HTTP layer (same pattern as TBinDistClientV1)
    function DoJsonRequest(Verb: THttpVerb; const Url: string;
      const Body: TJSONValue): TJSONValue;
    procedure DoBinaryPut(const Url: string; const Content: TBytes);

    // Parsing helpers
    function ParseDateTime(const DateStr: string): TDateTime;
    function ParseStringArray(JsonArray: TJSONArray): TArray<string>;
    function ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
    function ParseVersionInfo(Json: TJSONObject): TVersionInfo;
    function ParseCustomerInfo(Json: TJSONObject): TCustomerInfo;
    function ParseCreateCustomerResult(Json: TJSONObject): TCreateCustomerResult;
    function ParseUploadResult(Json: TJSONObject): TUploadResult;
    function ParseActivityEntry(Json: TJSONObject): TActivityEntry;
    function ParseJsonArray<T>(JsonArray: TJSONArray;
      Parser: TFunc<TJSONObject, T>): TArray<T>;
    function UrlEncode(const Value: string): string;

    // Error synthesis
    class function CodeFromStatus(StatusCode: Integer): string; static;
    class procedure RaiseApiError(StatusCode: Integer;
      const ResponseBody: string; const RequestId: string); static;
  public
    constructor Create(const BaseUrl, ApiKey: string);
    destructor Destroy; override;

    // IBinDistAdmin
    function CreateCustomer(const Name: string;
      const ParentCustomerId: string = 'admin';
      const Notes: string = ''): TCreateCustomerResult;

    function CreateApplication(
      const Options: TCreateApplicationOptions): TApplicationInfo;

    function UploadSmallFile(const ApplicationId, Version, FileName: string;
      const Content: TBytes; const ReleaseNotes: string = ''): TUploadResult;

    function UploadLargeFile(const ApplicationId, Version, FileName: string;
      const Content: TBytes; const ReleaseNotes: string = ''): TUploadResult;

    function UpdateVersion(const ApplicationId, Version: string;
      const Options: TUpdateVersionOptions): TVersionInfo;

    function UpdateCustomer(const CustomerId: string;
      const Options: TUpdateCustomerOptions): TCustomerInfo;

    procedure DeleteApplication(const ApplicationId: string);

    function ListActivity(const ActivityType, ApplicationId: string;
      Page, PageSize: Integer): TPaginatedResult<TArray<TActivityEntry>>;

    function ListCustomers(Page, PageSize: Integer):
      TPaginatedResult<TArray<TCustomerInfo>>;

    function GetStats(const ApplicationId: string): TStats;
  end;

implementation

uses
  System.NetEncoding;

type
  TResponseMeta = record
    RequestId: string;
    Pagination: TPagination;
    HasPagination: Boolean;
  end;

function ExtractMeta(Json: TJSONObject): TResponseMeta;
var
  MetaVal, PagVal: TJSONValue;
  MetaObj: TJSONObject;
begin
  Result.RequestId := '';
  Result.HasPagination := False;
  Result.Pagination := Default(TPagination);

  MetaVal := Json.GetValue('meta');
  if Assigned(MetaVal) and (MetaVal is TJSONObject) then
  begin
    MetaObj := TJSONObject(MetaVal);
    Result.RequestId := MetaObj.GetValue<string>('requestId', '');
    PagVal := MetaObj.GetValue('pagination');
    if Assigned(PagVal) and (PagVal is TJSONObject) then
    begin
      Result.HasPagination := True;
      Result.Pagination.Page := TJSONObject(PagVal).GetValue<Integer>('page', 1);
      Result.Pagination.Limit := TJSONObject(PagVal).GetValue<Integer>('limit', 20);
      Result.Pagination.Total := TJSONObject(PagVal).GetValue<Integer>('total', 0);
      Result.Pagination.HasNext := TJSONObject(PagVal).GetValue<Boolean>('hasNext', False);
      Result.Pagination.HasPrevious := TJSONObject(PagVal).GetValue<Boolean>('hasPrevious', False);
    end;
  end;
end;

{ TBinDistAdminV1 }

constructor TBinDistAdminV1.Create(const BaseUrl, ApiKey: string);
begin
  inherited Create;
  FBaseUrl := BaseUrl;
  if FBaseUrl.EndsWith('/') then
    FBaseUrl := Copy(FBaseUrl, 1, Length(FBaseUrl) - 1);
  FApiKey := ApiKey;
  FHttpClient := THTTPClient.Create;
  FHttpClient.ContentType := 'application/json';
end;

destructor TBinDistAdminV1.Destroy;
begin
  FHttpClient.Free;
  inherited;
end;

// ---------------------------------------------------------------------------
// Error synthesis — same table as customer client
// ---------------------------------------------------------------------------

class function TBinDistAdminV1.CodeFromStatus(StatusCode: Integer): string;
begin
  case StatusCode of
    400: Result := 'bad_request';
    401: Result := 'unauthorized';
    403: Result := 'forbidden';
    404: Result := 'not_found';
    409: Result := 'conflict';
    429: Result := 'rate_limited';
  else
    if StatusCode >= 500 then
      Result := 'server_error'
    else
      Result := 'http_error';
  end;
end;

class procedure TBinDistAdminV1.RaiseApiError(StatusCode: Integer;
  const ResponseBody: string; const RequestId: string);
var
  Json: TJSONValue;
  ErrorObj: TJSONObject;
  Code, Msg, ReqId: string;
begin
  Code := '';
  Msg := '';
  ReqId := RequestId;

  Json := TJSONObject.ParseJSONValue(ResponseBody);
  if Assigned(Json) then
  try
    if Json is TJSONObject then
    begin
      var ErrVal := TJSONObject(Json).GetValue('error');
      if Assigned(ErrVal) and (ErrVal is TJSONObject) then
      begin
        ErrorObj := TJSONObject(ErrVal);
        Code := ErrorObj.GetValue<string>('code', '');
        Msg := ErrorObj.GetValue<string>('message', '');
      end;

      if ReqId = '' then
      begin
        var MetaVal := TJSONObject(Json).GetValue('meta');
        if Assigned(MetaVal) and (MetaVal is TJSONObject) then
          ReqId := TJSONObject(MetaVal).GetValue<string>('requestId', '');
      end;

      if Msg = '' then
        Msg := TJSONObject(Json).GetValue<string>('message', '');

      if Msg = '' then
      begin
        var TopErr := TJSONObject(Json).GetValue('error');
        if Assigned(TopErr) and (TopErr is TJSONString) then
          Msg := TopErr.Value;
      end;
    end;
  finally
    Json.Free;
  end;

  if Msg = '' then
    Msg := Format('HTTP %d error', [StatusCode]);
  if Code = '' then
    Code := CodeFromStatus(StatusCode);

  raise EBinDistApiError.Create(Code, Msg, StatusCode, ReqId);
end;

// ---------------------------------------------------------------------------
// Internal HTTP layer
// ---------------------------------------------------------------------------

function TBinDistAdminV1.DoJsonRequest(Verb: THttpVerb;
  const Url: string; const Body: TJSONValue): TJSONValue;
var
  Response: IHTTPResponse;
  Headers: TNetHeaders;
  BodyStream: TStringStream;
  ResponseBody: string;
begin
  SetLength(Headers, 2);
  Headers[0] := TNetHeader.Create('Authorization', 'Bearer ' + FApiKey);
  Headers[1] := TNetHeader.Create('Content-Type', 'application/json');

  BodyStream := nil;
  try
    if Assigned(Body) then
      BodyStream := TStringStream.Create(Body.ToString, TEncoding.UTF8);

    try
      case Verb of
        hvGet:
          Response := FHttpClient.Get(Url, nil, Headers);
        hvPost:
          Response := FHttpClient.Post(Url, BodyStream, nil, Headers);
        hvPatch:
          Response := FHttpClient.Patch(Url, BodyStream, nil, Headers);
        hvDelete:
          Response := FHttpClient.Delete(Url, nil, Headers);
        hvPut:
          Response := FHttpClient.Put(Url, BodyStream, nil, Headers);
      end;
    except
      on E: Exception do
        raise EBinDistTransportError.Create(E.Message);
    end;

    ResponseBody := Response.ContentAsString;

    if Response.StatusCode >= 400 then
      RaiseApiError(Response.StatusCode, ResponseBody, '');

    Result := TJSONObject.ParseJSONValue(ResponseBody);
    if not Assigned(Result) then
      raise EBinDistTransportError.Create('Invalid JSON response');

  finally
    BodyStream.Free;
  end;
end;

procedure TBinDistAdminV1.DoBinaryPut(const Url: string;
  const Content: TBytes);
var
  Response: IHTTPResponse;
  Stream: TBytesStream;
  Headers: TNetHeaders;
begin
  // No auth header — uploading to pre-signed S3 URL
  SetLength(Headers, 1);
  Headers[0] := TNetHeader.Create('Content-Type', 'application/octet-stream');

  Stream := TBytesStream.Create(Content);
  try
    try
      Response := FHttpClient.Put(Url, Stream, nil, Headers);
    except
      on E: Exception do
        raise EBinDistTransportError.Create(E.Message);
    end;

    if Response.StatusCode <> 200 then
      raise EBinDistTransportError.CreateFmt('S3 upload failed with status %d',
        [Response.StatusCode]);
  finally
    Stream.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

function TBinDistAdminV1.ParseDateTime(const DateStr: string): TDateTime;
begin
  if DateStr <> '' then
  begin
    try
      Result := ISO8601ToDate(DateStr);
    except
      Result := 0;
    end;
  end
  else
    Result := 0;
end;

function TBinDistAdminV1.ParseStringArray(JsonArray: TJSONArray): TArray<string>;
var
  I: Integer;
begin
  if not Assigned(JsonArray) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := JsonArray.Items[I].Value;
end;

function TBinDistAdminV1.ParseJsonArray<T>(JsonArray: TJSONArray;
  Parser: TFunc<TJSONObject, T>): TArray<T>;
var
  I: Integer;
begin
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := Parser(JsonArray.Items[I] as TJSONObject);
end;


function TBinDistAdminV1.ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
var
  TagsVal: TJSONValue;
begin
  Result.ApplicationId := Json.GetValue<string>('applicationId', '');
  Result.Name := Json.GetValue<string>('name', '');
  Result.Description := Json.GetValue<string>('description', '');
  Result.IsActive := Json.GetValue<Boolean>('isActive', True);
  Result.CreatedAt := ParseDateTime(Json.GetValue<string>('createdAt', ''));
  Result.UpdatedAt := ParseDateTime(Json.GetValue<string>('updatedAt', ''));
  TagsVal := Json.GetValue('tags');
  if Assigned(TagsVal) and (TagsVal is TJSONArray) then
    Result.Tags := ParseStringArray(TJSONArray(TagsVal))
  else
    SetLength(Result.Tags, 0);
end;

function TBinDistAdminV1.ParseVersionInfo(Json: TJSONObject): TVersionInfo;
begin
  Result.VersionId := Json.GetValue<string>('versionId', '');
  Result.ApplicationId := Json.GetValue<string>('applicationId', '');
  Result.Version := Json.GetValue<string>('version', '');
  Result.ReleaseNotes := Json.GetValue<string>('releaseNotes', '');
  Result.IsActive := Json.GetValue<Boolean>('isActive', True);
  Result.IsEnabled := Json.GetValue<Boolean>('isEnabled', True);
  Result.CreatedAt := ParseDateTime(Json.GetValue<string>('createdAt', ''));
  Result.UpdatedAt := ParseDateTime(Json.GetValue<string>('updatedAt', ''));
  Result.FileSize := Json.GetValue<Int64>('fileSize', 0);
  Result.DownloadCount := Json.GetValue<Integer>('downloadCount', 0);
end;

function TBinDistAdminV1.ParseCustomerInfo(Json: TJSONObject): TCustomerInfo;
begin
  Result.CustomerId := Json.GetValue<string>('customerId', '');
  Result.Name := Json.GetValue<string>('name', '');
  Result.ApiKey := Json.GetValue<string>('apiKey', '');
  Result.IsActive := Json.GetValue<Boolean>('isActive', True);
  Result.Notes := Json.GetValue<string>('notes', '');
  Result.CreatedAt := ParseDateTime(Json.GetValue<string>('createdAt', ''));
end;

function TBinDistAdminV1.ParseCreateCustomerResult(Json: TJSONObject): TCreateCustomerResult;
begin
  Result.CustomerId := Json.GetValue<string>('customerId', '');
  Result.ApiKey := Json.GetValue<string>('apiKey', '');
  Result.Name := Json.GetValue<string>('name', '');
  Result.CreatedAt := Json.GetValue<string>('createdAt', '');
end;

function TBinDistAdminV1.ParseUploadResult(Json: TJSONObject): TUploadResult;
begin
  Result.Message := Json.GetValue<string>('message', '');
  Result.VersionId := Json.GetValue<string>('versionId', '');
  Result.ApplicationId := Json.GetValue<string>('applicationId', '');
  Result.Version := Json.GetValue<string>('version', '');
  Result.FileSize := Json.GetValue<Int64>('fileSize', 0);
  Result.Checksum := Json.GetValue<string>('checksum', '');
end;

function TBinDistAdminV1.ParseActivityEntry(Json: TJSONObject): TActivityEntry;
begin
  Result.ActivityType := Json.GetValue<string>('type', '');
  Result.ApplicationId := Json.GetValue<string>('applicationId', '');
  Result.Version := Json.GetValue<string>('version', '');
  Result.CustomerId := Json.GetValue<string>('customerId', '');
  Result.Timestamp := ParseDateTime(Json.GetValue<string>('timestamp', ''));
end;

function TBinDistAdminV1.UrlEncode(const Value: string): string;
begin
  Result := TNetEncoding.URL.Encode(Value);
end;

// ---------------------------------------------------------------------------
// IBinDistAdmin implementation
// ---------------------------------------------------------------------------

function TBinDistAdminV1.CreateCustomer(const Name: string;
  const ParentCustomerId: string; const Notes: string): TCreateCustomerResult;
var
  Payload: TJSONObject;
  Json: TJSONValue;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('name', Name);
    if Notes <> '' then
      Payload.AddPair('notes', Notes);

    Path := Format('%s/v1/management/customers/%s/apikeys',
      [FBaseUrl, UrlEncode(ParentCustomerId)]);
    Json := DoJsonRequest(hvPost, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseCreateCustomerResult(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.CreateApplication(
  const Options: TCreateApplicationOptions): TApplicationInfo;
var
  Payload: TJSONObject;
  CustArray, TagsArray: TJSONArray;
  Json: TJSONValue;
  DataObj: TJSONObject;
  S: string;
begin
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('applicationId', Options.ApplicationId);
    Payload.AddPair('name', Options.Name);

    if Length(Options.CustomerIds) > 0 then
    begin
      CustArray := TJSONArray.Create;
      for S in Options.CustomerIds do
        CustArray.Add(S);
      Payload.AddPair('customerIds', CustArray);
    end;

    if Options.Description <> '' then
      Payload.AddPair('description', Options.Description);

    if Length(Options.Tags) > 0 then
    begin
      TagsArray := TJSONArray.Create;
      for S in Options.Tags do
        TagsArray.Add(S);
      Payload.AddPair('tags', TagsArray);
    end;

    Json := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/applications', Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseApplicationInfo(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.UploadSmallFile(const ApplicationId, Version,
  FileName: string; const Content: TBytes;
  const ReleaseNotes: string): TUploadResult;
var
  Payload: TJSONObject;
  Json: TJSONValue;
  DataObj: TJSONObject;
begin
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('applicationId', ApplicationId);
    Payload.AddPair('version', Version);
    Payload.AddPair('fileName', FileName);
    Payload.AddPair('fileContent',
      TNetEncoding.Base64.EncodeBytesToString(Content));
    Payload.AddPair('fileType', 'MAIN');
    if ReleaseNotes <> '' then
      Payload.AddPair('releaseNotes', ReleaseNotes);

    Json := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload', Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseUploadResult(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.UploadLargeFile(const ApplicationId, Version,
  FileName: string; const Content: TBytes;
  const ReleaseNotes: string): TUploadResult;
var
  FileSize: Int64;
  Checksum: string;
  Hash: THashSHA2;
  // Step 1
  UrlPayload: TJSONObject;
  UrlJson: TJSONValue;
  UrlDataObj: TJSONObject;
  UploadId, UploadUrl: string;
  // Step 3
  CompletePayload: TJSONObject;
  CompleteJson: TJSONValue;
  CompleteDataObj: TJSONObject;
begin
  FileSize := Length(Content);

  // Compute SHA256 checksum
  Hash := THashSHA2.Create;
  Hash.Update(Content, Length(Content));
  Checksum := LowerCase(Hash.HashAsString);

  // Step 1: Get pre-signed upload URL
  UrlPayload := TJSONObject.Create;
  try
    UrlPayload.AddPair('applicationId', ApplicationId);
    UrlPayload.AddPair('version', Version);
    UrlPayload.AddPair('fileName', FileName);
    UrlPayload.AddPair('fileSize', TJSONNumber.Create(FileSize));
    UrlPayload.AddPair('contentType', 'application/octet-stream');

    UrlJson := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload/large-url', UrlPayload);
  finally
    UrlPayload.Free;
  end;

  try
    if not (UrlJson is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    UrlDataObj := TJSONObject(UrlJson).GetValue('data') as TJSONObject;
    if not Assigned(UrlDataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    UploadId := UrlDataObj.GetValue<string>('uploadId', '');
    UploadUrl := UrlDataObj.GetValue<string>('uploadUrl', '');
  finally
    UrlJson.Free;
  end;

  // Step 2: PUT binary to S3
  DoBinaryPut(UploadUrl, Content);

  // Step 3: Complete the upload
  CompletePayload := TJSONObject.Create;
  try
    CompletePayload.AddPair('uploadId', UploadId);
    CompletePayload.AddPair('applicationId', ApplicationId);
    CompletePayload.AddPair('version', Version);
    CompletePayload.AddPair('fileName', FileName);
    CompletePayload.AddPair('fileSize', TJSONNumber.Create(FileSize));
    CompletePayload.AddPair('checksum', Checksum);
    if ReleaseNotes <> '' then
      CompletePayload.AddPair('releaseNotes', ReleaseNotes);

    CompleteJson := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload/large-complete', CompletePayload);
  finally
    CompletePayload.Free;
  end;

  try
    if not (CompleteJson is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    CompleteDataObj := TJSONObject(CompleteJson).GetValue('data') as TJSONObject;
    if not Assigned(CompleteDataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseUploadResult(CompleteDataObj);
  finally
    CompleteJson.Free;
  end;
end;

function TBinDistAdminV1.UpdateVersion(const ApplicationId, Version: string;
  const Options: TUpdateVersionOptions): TVersionInfo;
var
  Payload: TJSONObject;
  Json: TJSONValue;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    if Options.IsEnabledSet then
      Payload.AddPair('isEnabled', TJSONBool.Create(Options.IsEnabled));
    if Options.IsActiveSet then
      Payload.AddPair('isActive', TJSONBool.Create(Options.IsActive));
    if Options.ReleaseNotesSet then
      Payload.AddPair('releaseNotes', Options.ReleaseNotes);

    Path := Format('%s/v1/applications/%s/versions/%s',
      [FBaseUrl, UrlEncode(ApplicationId), UrlEncode(Version)]);
    Json := DoJsonRequest(hvPatch, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseVersionInfo(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.UpdateCustomer(const CustomerId: string;
  const Options: TUpdateCustomerOptions): TCustomerInfo;
var
  Payload: TJSONObject;
  Json: TJSONValue;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    if Options.NameSet then
      Payload.AddPair('name', Options.Name);
    if Options.IsActiveSet then
      Payload.AddPair('isActive', TJSONBool.Create(Options.IsActive));
    if Options.NotesSet then
      Payload.AddPair('notes', Options.Notes);

    Path := Format('%s/v1/management/customers/%s',
      [FBaseUrl, UrlEncode(CustomerId)]);
    Json := DoJsonRequest(hvPatch, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseCustomerInfo(DataObj);
  finally
    Json.Free;
  end;
end;

procedure TBinDistAdminV1.DeleteApplication(const ApplicationId: string);
var
  Path: string;
  Json: TJSONValue;
begin
  Path := Format('%s/v1/management/applications/%s',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvDelete, Path, nil);
  Json.Free;
end;

function TBinDistAdminV1.ListActivity(const ActivityType,
  ApplicationId: string; Page, PageSize: Integer):
  TPaginatedResult<TArray<TActivityEntry>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  ActivitiesArray: TJSONArray;
  Meta: TResponseMeta;
  Query: string;
begin
  SetLength(Params, 0);

  if ActivityType <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('type', ActivityType);
  end;
  if ApplicationId <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('applicationId', ApplicationId);
  end;
  if Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Page));
  end;
  if PageSize > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('pageSize', IntToStr(PageSize));
  end;

  // Build query string
  Query := '';
  if Length(Params) > 0 then
  begin
    Query := '?' + Params[0].Key + '=' + UrlEncode(Params[0].Value);
    for var I := 1 to High(Params) do
      Query := Query + '&' + Params[I].Key + '=' + UrlEncode(Params[I].Value);
  end;

  RequestUrl := FBaseUrl + '/v1/activity' + Query;
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    ActivitiesArray := DataObj.GetValue('activities') as TJSONArray;
    if Assigned(ActivitiesArray) then
      Result.Items := ParseJsonArray<TActivityEntry>(ActivitiesArray, ParseActivityEntry)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    if Meta.HasPagination then
      Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.ListCustomers(Page, PageSize: Integer):
  TPaginatedResult<TArray<TCustomerInfo>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl, Query: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  CustomersArray: TJSONArray;
  Meta: TResponseMeta;
begin
  SetLength(Params, 0);

  if Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Page));
  end;
  if PageSize > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('pageSize', IntToStr(PageSize));
  end;

  Query := '';
  if Length(Params) > 0 then
  begin
    Query := '?' + Params[0].Key + '=' + UrlEncode(Params[0].Value);
    for var I := 1 to High(Params) do
      Query := Query + '&' + Params[I].Key + '=' + UrlEncode(Params[I].Value);
  end;

  RequestUrl := FBaseUrl + '/v1/management/customers' + Query;
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    CustomersArray := DataObj.GetValue('customers') as TJSONArray;
    if Assigned(CustomersArray) then
      Result.Items := ParseJsonArray<TCustomerInfo>(CustomersArray, ParseCustomerInfo)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    if Meta.HasPagination then
      Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.GetStats(const ApplicationId: string): TStats;
var
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
begin
  RequestUrl := Format('%s/v1/applications/%s/stats',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result.TotalDownloads := DataObj.GetValue<Integer>('totalDownloads', 0);
  finally
    Json.Free;
  end;
end;

end.
