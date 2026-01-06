unit BinDist.ClientV1;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Net.HttpClient,
  System.Net.URLClient, System.DateUtils, System.NetConsts,
  System.Generics.Collections, System.Hash,
  BinDist.Interfaces, BinDist.Exceptions;

type
  THttpVerb = (hvGet, hvPost, hvPatch, hvDelete, hvPut);

  TBinDistClientV1 = class(TInterfacedObject, IBinDistClient)
  private
    FApiKey: string;
    FBaseUrl: string;
    FHttpClient: THTTPClient;

    // Internal HTTP layer
    function DoJsonRequest(Verb: THttpVerb; const Url: string;
      const Body: TJSONValue;
      const Options: TRequestOptions): TJSONValue;
    procedure DoDownload(const Url: string; Stream: TStream);

    // Response parsing helpers
    function ParseDateTime(const DateStr: string): TDateTime;
    function ParseStringArray(JsonArray: TJSONArray): TArray<string>;
    function ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
    function ParseVersionInfo(Json: TJSONObject): TVersionInfo;
    function ParseVersionFile(Json: TJSONObject): TVersionFile;
    function ParseDownloadInfo(Json: TJSONObject): TDownloadInfo;
    function ParseShareLink(Json: TJSONObject): TShareLink;
    function ParseJsonArray<T>(JsonArray: TJSONArray;
      Parser: TFunc<TJSONObject, T>): TArray<T>;

    // URL helpers
    function BuildQueryString(
      const Params: TArray<TPair<string, string>>): string;
    function UrlEncode(const Value: string): string;

    // Error synthesis (matches Go's httpStatusCode + synthesizeError)
    class function CodeFromStatus(StatusCode: Integer): string; static;
    class procedure RaiseApiError(StatusCode: Integer;
      const ResponseBody: string; const RequestId: string); static;

    // Internal download + checksum
    procedure InternalDownloadToStream(const ApplicationId, Version: string;
      Stream: TStream; const Options: TRequestOptions;
      VerifyChecksum: Boolean; const FileId: string);
  public
    constructor Create(const BaseUrl, ApiKey: string);
    destructor Destroy; override;

    // IBinDistClient
    function ListApplications: TPaginatedResult<TArray<TApplicationInfo>>; overload;
    function ListApplications(const Options: TListApplicationsOptions):
      TPaginatedResult<TArray<TApplicationInfo>>; overload;

    function GetApplication(const ApplicationId: string): TApplicationInfo;

    function ListVersions(const ApplicationId: string):
      TPaginatedResult<TArray<TVersionInfo>>; overload;
    function ListVersions(const ApplicationId: string;
      const Options: TRequestOptions):
      TPaginatedResult<TArray<TVersionInfo>>; overload;

    function ListVersionFiles(const ApplicationId, Version: string):
      TPaginatedResult<TArray<TVersionFile>>;

    function GetDownloadInfo(const ApplicationId, Version: string;
      const FileId: string = ''): TDownloadInfo; overload;
    function GetDownloadInfo(const ApplicationId, Version, FileId: string;
      const Options: TRequestOptions): TDownloadInfo; overload;

    procedure DownloadFile(const ApplicationId, Version, OutputPath: string;
      VerifyChecksum: Boolean = True; const FileId: string = ''); overload;
    procedure DownloadFile(const ApplicationId, Version, OutputPath: string;
      const Options: TRequestOptions; VerifyChecksum: Boolean = True;
      const FileId: string = ''); overload;

    procedure DownloadFileToStream(const ApplicationId, Version: string;
      Stream: TStream; VerifyChecksum: Boolean = True;
      const FileId: string = ''); overload;
    procedure DownloadFileToStream(const ApplicationId, Version: string;
      Stream: TStream; const Options: TRequestOptions;
      VerifyChecksum: Boolean = True; const FileId: string = ''); overload;

    function CreateShareLink(const ApplicationId, Version: string;
      ExpiresMinutes: Integer; const FileId: string = ''): TShareLink;
  end;

implementation

uses
  System.NetEncoding;

{ TBinDistClientV1 }

constructor TBinDistClientV1.Create(const BaseUrl, ApiKey: string);
begin
  inherited Create;
  FBaseUrl := BaseUrl;
  if FBaseUrl.EndsWith('/') then
    FBaseUrl := Copy(FBaseUrl, 1, Length(FBaseUrl) - 1);
  FApiKey := ApiKey;
  FHttpClient := THTTPClient.Create;
  FHttpClient.ContentType := 'application/json';
end;

destructor TBinDistClientV1.Destroy;
begin
  FHttpClient.Free;
  inherited;
end;

// ---------------------------------------------------------------------------
// Error synthesis — matches Go's httpStatusCode table
// ---------------------------------------------------------------------------

class function TBinDistClientV1.CodeFromStatus(StatusCode: Integer): string;
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

class procedure TBinDistClientV1.RaiseApiError(StatusCode: Integer;
  const ResponseBody: string; const RequestId: string);
var
  Json: TJSONValue;
  ErrorObj: TJSONObject;
  Code, Msg: string;
  ReqId: string;
begin
  Code := '';
  Msg := '';
  ReqId := RequestId;

  Json := TJSONObject.ParseJSONValue(ResponseBody);
  if Assigned(Json) then
  try
    if Json is TJSONObject then
    begin
      // 1. Standard envelope: {"success":false,"error":{"code":"...","message":"..."}}
      var ErrVal := TJSONObject(Json).GetValue('error');
      if Assigned(ErrVal) and (ErrVal is TJSONObject) then
      begin
        ErrorObj := TJSONObject(ErrVal);
        Code := ErrorObj.GetValue<string>('code', '');
        Msg := ErrorObj.GetValue<string>('message', '');
      end;

      // Extract requestId from meta if present
      if ReqId = '' then
      begin
        var MetaVal := TJSONObject(Json).GetValue('meta');
        if Assigned(MetaVal) and (MetaVal is TJSONObject) then
          ReqId := TJSONObject(MetaVal).GetValue<string>('requestId', '');
      end;

      // 2. Bare {"message":"..."} (auth middleware)
      if Msg = '' then
        Msg := TJSONObject(Json).GetValue<string>('message', '');

      // 3. Bare {"error":"..."} (string error)
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

  // 4. Fall back to generic message
  if Msg = '' then
    Msg := Format('HTTP %d error', [StatusCode]);

  if Code = '' then
    Code := CodeFromStatus(StatusCode);

  raise EBinDistApiError.Create(Code, Msg, StatusCode, ReqId);
end;

// ---------------------------------------------------------------------------
// Internal HTTP layer
// ---------------------------------------------------------------------------

function TBinDistClientV1.DoJsonRequest(Verb: THttpVerb; const Url: string;
  const Body: TJSONValue; const Options: TRequestOptions): TJSONValue;
var
  Response: IHTTPResponse;
  Headers: TNetHeaders;
  BodyStream: TStringStream;
  HeaderCount: Integer;
  ResponseBody: string;
begin
  HeaderCount := 2;
  if Options.Channel <> '' then
    Inc(HeaderCount);

  SetLength(Headers, HeaderCount);
  Headers[0] := TNetHeader.Create('Authorization', 'Bearer ' + FApiKey);
  Headers[1] := TNetHeader.Create('Content-Type', 'application/json');
  if Options.Channel <> '' then
    Headers[2] := TNetHeader.Create('X-Channel', Options.Channel);

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

procedure TBinDistClientV1.DoDownload(const Url: string; Stream: TStream);
var
  Response: IHTTPResponse;
begin
  try
    // No auth header — downloading from pre-signed S3 URL
    Response := FHttpClient.Get(Url, Stream);
  except
    on E: Exception do
      raise EBinDistTransportError.Create(E.Message);
  end;

  if Response.StatusCode <> 200 then
    raise EBinDistTransportError.CreateFmt('download failed with status %d',
      [Response.StatusCode]);
end;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

function TBinDistClientV1.ParseDateTime(const DateStr: string): TDateTime;
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

function TBinDistClientV1.ParseStringArray(JsonArray: TJSONArray): TArray<string>;
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

function TBinDistClientV1.ParseJsonArray<T>(JsonArray: TJSONArray;
  Parser: TFunc<TJSONObject, T>): TArray<T>;
var
  I: Integer;
begin
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := Parser(JsonArray.Items[I] as TJSONObject);
end;


function TBinDistClientV1.ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
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

function TBinDistClientV1.ParseVersionInfo(Json: TJSONObject): TVersionInfo;
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

function TBinDistClientV1.ParseVersionFile(Json: TJSONObject): TVersionFile;
begin
  Result.FileId := Json.GetValue<string>('fileId', '');
  Result.FileName := Json.GetValue<string>('fileName', '');
  Result.FileType := Json.GetValue<string>('fileType', '');
  Result.FileSize := Json.GetValue<Int64>('fileSize', 0);
  Result.Checksum := Json.GetValue<string>('checksum', '');
  Result.Order := Json.GetValue<Integer>('order', 0);
  Result.Description := Json.GetValue<string>('description', '');
end;

function TBinDistClientV1.ParseDownloadInfo(Json: TJSONObject): TDownloadInfo;
begin
  Result.DownloadId := Json.GetValue<string>('downloadId', '');
  Result.Url := Json.GetValue<string>('url', '');
  Result.ExpiresAt := ParseDateTime(Json.GetValue<string>('expiresAt', ''));
  Result.FileName := Json.GetValue<string>('fileName', '');
  Result.FileSize := Json.GetValue<Int64>('fileSize', 0);
  Result.Checksum := Json.GetValue<string>('checksum', '');
end;

function TBinDistClientV1.ParseShareLink(Json: TJSONObject): TShareLink;
begin
  Result.ShareUrl := Json.GetValue<string>('shareUrl', '');
  Result.ExpiresAt := ParseDateTime(Json.GetValue<string>('expiresAt', ''));
end;

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function TBinDistClientV1.UrlEncode(const Value: string): string;
begin
  Result := TNetEncoding.URL.Encode(Value);
end;

function TBinDistClientV1.BuildQueryString(
  const Params: TArray<TPair<string, string>>): string;
var
  Pair: TPair<string, string>;
  First: Boolean;
begin
  Result := '';
  First := True;
  for Pair in Params do
  begin
    if Pair.Value <> '' then
    begin
      if First then
      begin
        Result := '?';
        First := False;
      end
      else
        Result := Result + '&';
      Result := Result + Pair.Key + '=' + UrlEncode(Pair.Value);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Helper to extract meta/pagination from a standard API response
// ---------------------------------------------------------------------------

type
  TResponseMeta = record
    RequestId: string;
    Pagination: TPagination;
    HasPagination: Boolean;
  end;

function ExtractMeta(Json: TJSONObject): TResponseMeta;
var
  MetaObj: TJSONObject;
  MetaVal, PagVal: TJSONValue;
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

// ---------------------------------------------------------------------------
// IBinDistClient — Customer methods
// ---------------------------------------------------------------------------

function TBinDistClientV1.ListApplications: TPaginatedResult<TArray<TApplicationInfo>>;
var
  EmptyOpts: TListApplicationsOptions;
begin
  EmptyOpts := Default(TListApplicationsOptions);
  Result := ListApplications(EmptyOpts);
end;

function TBinDistClientV1.ListApplications(
  const Options: TListApplicationsOptions): TPaginatedResult<TArray<TApplicationInfo>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  AppsArray: TJSONArray;
  Meta: TResponseMeta;
  DefaultOpts: TRequestOptions;
begin
  SetLength(Params, 0);

  if Options.Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Options.Page));
  end;

  if Options.PageSize > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('pageSize', IntToStr(Options.PageSize));
  end;

  if Options.Search <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('search', Options.Search);
  end;

  if Length(Options.Tags) > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('tags',
      string.Join(',', Options.Tags));
  end;

  RequestUrl := Format('%s/v1/applications%s', [FBaseUrl, BuildQueryString(Params)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    AppsArray := DataObj.GetValue('applications') as TJSONArray;
    if Assigned(AppsArray) then
      Result.Items := ParseJsonArray<TApplicationInfo>(AppsArray, ParseApplicationInfo)
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

function TBinDistClientV1.GetApplication(
  const ApplicationId: string): TApplicationInfo;
var
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  DefaultOpts: TRequestOptions;
begin
  RequestUrl := Format('%s/v1/applications/%s',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
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

function TBinDistClientV1.ListVersions(
  const ApplicationId: string): TPaginatedResult<TArray<TVersionInfo>>;
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  Result := ListVersions(ApplicationId, DefaultOpts);
end;

function TBinDistClientV1.ListVersions(const ApplicationId: string;
  const Options: TRequestOptions): TPaginatedResult<TArray<TVersionInfo>>;
var
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  VersionsArray: TJSONArray;
  Meta: TResponseMeta;
begin
  RequestUrl := Format('%s/v1/applications/%s/versions',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, Options);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    VersionsArray := DataObj.GetValue('versions') as TJSONArray;
    if Assigned(VersionsArray) then
      Result.Items := ParseJsonArray<TVersionInfo>(VersionsArray, ParseVersionInfo)
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

function TBinDistClientV1.ListVersionFiles(
  const ApplicationId, Version: string): TPaginatedResult<TArray<TVersionFile>>;
var
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
  FilesArray: TJSONArray;
  Meta: TResponseMeta;
  DefaultOpts: TRequestOptions;
begin
  RequestUrl := Format('%s/v1/applications/%s/versions/%s/files',
    [FBaseUrl, UrlEncode(ApplicationId), UrlEncode(Version)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    FilesArray := DataObj.GetValue('files') as TJSONArray;
    if Assigned(FilesArray) then
      Result.Items := ParseJsonArray<TVersionFile>(FilesArray, ParseVersionFile)
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

function TBinDistClientV1.GetDownloadInfo(const ApplicationId, Version: string;
  const FileId: string): TDownloadInfo;
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  Result := GetDownloadInfo(ApplicationId, Version, FileId, DefaultOpts);
end;

function TBinDistClientV1.GetDownloadInfo(const ApplicationId, Version,
  FileId: string; const Options: TRequestOptions): TDownloadInfo;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONValue;
  DataObj: TJSONObject;
begin
  SetLength(Params, 2);
  Params[0] := TPair<string, string>.Create('applicationId', ApplicationId);
  Params[1] := TPair<string, string>.Create('version', Version);

  if FileId <> '' then
  begin
    SetLength(Params, 3);
    Params[2] := TPair<string, string>.Create('fileId', FileId);
  end;

  RequestUrl := Format('%s/v1/downloads/url%s',
    [FBaseUrl, BuildQueryString(Params)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, Options);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseDownloadInfo(DataObj);
  finally
    Json.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Download with checksum verification
// ---------------------------------------------------------------------------

procedure TBinDistClientV1.InternalDownloadToStream(
  const ApplicationId, Version: string; Stream: TStream;
  const Options: TRequestOptions; VerifyChecksum: Boolean;
  const FileId: string);
var
  Info: TDownloadInfo;
  TempStream: TMemoryStream;
  Hash: THashSHA2;
  Buf: TBytes;
  ActualChecksum: string;
begin
  Info := GetDownloadInfo(ApplicationId, Version, FileId, Options);

  if VerifyChecksum and (Info.Checksum <> '') then
  begin
    // Download to temp memory stream for checksum verification
    TempStream := TMemoryStream.Create;
    try
      DoDownload(Info.Url, TempStream);

      // Compute SHA256 from downloaded bytes
      TempStream.Position := 0;
      SetLength(Buf, TempStream.Size);
      if TempStream.Size > 0 then
        TempStream.ReadBuffer(Buf[0], TempStream.Size);

      Hash := THashSHA2.Create;
      Hash.Update(Buf, Length(Buf));
      ActualChecksum := LowerCase(Hash.HashAsString);

      if ActualChecksum <> LowerCase(Info.Checksum) then
        raise EBinDistChecksumMismatch.Create(Info.Checksum, ActualChecksum);

      // Copy to target stream
      TempStream.Position := 0;
      Stream.CopyFrom(TempStream, TempStream.Size);
    finally
      TempStream.Free;
    end;
  end
  else
    DoDownload(Info.Url, Stream);
end;

procedure TBinDistClientV1.DownloadFile(const ApplicationId, Version,
  OutputPath: string; VerifyChecksum: Boolean; const FileId: string);
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  DownloadFile(ApplicationId, Version, OutputPath, DefaultOpts,
    VerifyChecksum, FileId);
end;

procedure TBinDistClientV1.DownloadFile(const ApplicationId, Version,
  OutputPath: string; const Options: TRequestOptions;
  VerifyChecksum: Boolean; const FileId: string);
var
  FileStream: TFileStream;
  Dir: string;
begin
  Dir := ExtractFilePath(OutputPath);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);

  FileStream := TFileStream.Create(OutputPath, fmCreate);
  try
    InternalDownloadToStream(ApplicationId, Version, FileStream, Options,
      VerifyChecksum, FileId);
  finally
    FileStream.Free;
  end;
end;

procedure TBinDistClientV1.DownloadFileToStream(const ApplicationId,
  Version: string; Stream: TStream; VerifyChecksum: Boolean;
  const FileId: string);
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  DownloadFileToStream(ApplicationId, Version, Stream, DefaultOpts,
    VerifyChecksum, FileId);
end;

procedure TBinDistClientV1.DownloadFileToStream(const ApplicationId,
  Version: string; Stream: TStream; const Options: TRequestOptions;
  VerifyChecksum: Boolean; const FileId: string);
begin
  InternalDownloadToStream(ApplicationId, Version, Stream, Options,
    VerifyChecksum, FileId);
end;

// ---------------------------------------------------------------------------
// CreateShareLink
// ---------------------------------------------------------------------------

function TBinDistClientV1.CreateShareLink(const ApplicationId, Version: string;
  ExpiresMinutes: Integer; const FileId: string): TShareLink;
var
  Payload: TJSONObject;
  Json: TJSONValue;
  DataObj: TJSONObject;
  DefaultOpts: TRequestOptions;
begin
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('applicationId', ApplicationId);
    Payload.AddPair('version', Version);
    Payload.AddPair('expiresMinutes', TJSONNumber.Create(ExpiresMinutes));
    if FileId <> '' then
      Payload.AddPair('fileId', FileId);

    DefaultOpts := Default(TRequestOptions);
    Json := DoJsonRequest(hvPost, FBaseUrl + '/v1/downloads/share',
      Payload, DefaultOpts);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).GetValue('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseShareLink(DataObj);
  finally
    Json.Free;
  end;
end;

end.
