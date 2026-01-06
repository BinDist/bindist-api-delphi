unit BinDist.Exceptions;

interface

uses
  System.SysUtils;

type
  /// Base class for all BinDist SDK exceptions.
  EBinDistError = class(Exception);

  /// Network failure, timeout, connection reset, malformed JSON,
  /// or anything that prevented us from getting a structured response
  /// from the server.
  EBinDistTransportError = class(EBinDistError);

  /// The server returned a non-2xx response with either a structured
  /// error envelope or a synthesized code/message from the HTTP status.
  EBinDistApiError = class(EBinDistError)
  public
    Code: string;
    StatusCode: Integer;
    RequestId: string;
    constructor Create(const ACode, AMessage: string;
      AStatusCode: Integer; const ARequestId: string);
  end;

  /// Raised when checksum verification fails during download.
  EBinDistChecksumMismatch = class(EBinDistError)
  public
    Expected: string;
    Actual: string;
    constructor Create(const AExpected, AActual: string);
  end;

implementation

constructor EBinDistApiError.Create(const ACode, AMessage: string;
  AStatusCode: Integer; const ARequestId: string);
begin
  inherited Create(AMessage);
  Code := ACode;
  StatusCode := AStatusCode;
  RequestId := ARequestId;
end;

constructor EBinDistChecksumMismatch.Create(const AExpected, AActual: string);
begin
  inherited CreateFmt('checksum mismatch: expected %s, got %s', [AExpected, AActual]);
  Expected := AExpected;
  Actual := AActual;
end;

end.
