# BinDist Delphi SDK

Delphi client library for the [BinDist](https://bindist.eu) binary distribution API. Provides both a **customer client** (list applications, download files, verify checksums) and an **admin client** (create applications, upload versions, manage customers).

## Requirements

- Delphi 10.3 Rio or later (uses `System.Net.HttpClient`, `System.Hash`)

## Installation

Add the following units to your project:

- `BinDist.Exceptions.pas` — Exception hierarchy
- `BinDist.Interfaces.pas` — Interfaces and type definitions
- `BinDist.ClientV1.pas` — Customer client implementation
- `BinDist.AdminV1.pas` — Admin client implementation
- `BinDist.Factory.pas` — Factory functions

## API Key Format

The shape of the API key depends on the deployment:

- **Hosted** (`api.bindist.eu`, multi-tenant): `{tenant_id}.{secret}` — tenant ID and secret joined by a dot.
- **Self-hosted** (single-tenant): just the secret. No tenant prefix needed.

The SDK does not validate the key — it is passed verbatim in the `Authorization: Bearer` header.

## Quick Start — Customer Client

```pascal
uses
  BinDist.Interfaces, BinDist.Factory, BinDist.Exceptions;

var
  Client: IBinDistClient;
  Apps: TPaginatedResult<TArray<TApplicationInfo>>;
  App: TApplicationInfo;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  try
    Apps := Client.ListApplications;
    for App in Apps.Items do
      WriteLn(App.Name);
  except
    on E: EBinDistApiError do
      WriteLn(Format('API error [%s]: %s', [E.Code, E.Message]));
    on E: EBinDistTransportError do
      WriteLn('Network error: ' + E.Message);
  end;
end;
```

## Listing Versions (with Channel)

```pascal
var
  Client: IBinDistClient;
  Opts: TRequestOptions;
  Versions: TPaginatedResult<TArray<TVersionInfo>>;
  V: TVersionInfo;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  // Production channel (default)
  Versions := Client.ListVersions('myapp');

  // Test channel — includes disabled/pre-release versions
  Opts.Channel := 'Test';
  Versions := Client.ListVersions('myapp', Opts);

  for V in Versions.Items do
    WriteLn(Format('%s (enabled=%s)', [V.Version, BoolToStr(V.IsEnabled, True)]));
end;
```

## Downloading a File

`DownloadFile` internally calls `GetDownloadInfo` to obtain the pre-signed URL, downloads the bytes, and verifies the SHA256 checksum by default.

```pascal
var
  Client: IBinDistClient;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  try
    // Downloads with checksum verification (default)
    Client.DownloadFile('myapp', '1.0.0', 'C:\Downloads\myapp.exe');
  except
    on E: EBinDistChecksumMismatch do
      WriteLn(Format('Checksum failed: expected %s, got %s', [E.Expected, E.Actual]));
    on E: EBinDistApiError do
      WriteLn('API error: ' + E.Message);
  end;
end;
```

To download without checksum verification:

```pascal
Client.DownloadFile('myapp', '1.0.0', 'C:\Downloads\myapp.exe',
  False {VerifyChecksum});
```

To download a specific file in a multi-file version:

```pascal
Client.DownloadFile('myapp', '1.0.0', 'C:\Downloads\patch.exe',
  True {VerifyChecksum}, 'file-id-here');
```

## Download to Stream

```pascal
var
  Client: IBinDistClient;
  Stream: TMemoryStream;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  Stream := TMemoryStream.Create;
  try
    Client.DownloadFileToStream('myapp', '1.0.0', Stream);
    WriteLn('Downloaded ', Stream.Size, ' bytes');
  finally
    Stream.Free;
  end;
end;
```

## Share Links

```pascal
var
  Client: IBinDistClient;
  Link: TShareLink;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  Link := Client.CreateShareLink('myapp', '1.0.0', 60 {minutes});
  WriteLn('Share URL: ' + Link.ShareUrl);
end;
```

## Admin Client

```pascal
uses
  BinDist.Interfaces, BinDist.Factory, BinDist.Exceptions;

var
  Admin: IBinDistAdmin;
  App: TApplicationInfo;
  Upload: TUploadResult;
  CreateOpts: TCreateApplicationOptions;
  Content: TBytes;
begin
  Admin := CreateBinDistAdminClient('https://api.bindist.eu', 'admin-api-key');

  // Create an application
  CreateOpts.ApplicationId := 'myapp';
  CreateOpts.Name := 'My Application';
  SetLength(CreateOpts.CustomerIds, 1);
  CreateOpts.CustomerIds[0] := 'customer-id';
  App := Admin.CreateApplication(CreateOpts);

  // Upload a small file (< 10 MB)
  // (requires System.IOUtils for TFile)
  Content := TFile.ReadAllBytes('C:\build\myapp.exe');
  Upload := Admin.UploadSmallFile('myapp', '1.0.0', 'myapp.exe', Content,
    'Initial release');

  // Upload a large file (>= 10 MB) — uses multi-step S3 upload
  Upload := Admin.UploadLargeFile('myapp', '2.0.0', 'myapp.exe', Content,
    'Major update');

  // Update version metadata
  var VerOpts: TUpdateVersionOptions;
  VerOpts := Default(TUpdateVersionOptions);
  VerOpts.IsEnabledSet := True;
  VerOpts.IsEnabled := True;
  Admin.UpdateVersion('myapp', '1.0.0', VerOpts);

  // Get application stats (admin-only)
  var Stats: TStats;
  Stats := Admin.GetStats('myapp');
  WriteLn('Total downloads: ', Stats.TotalDownloads);

  // Delete an application
  Admin.DeleteApplication('old-app');
end;
```

## Error Handling

All methods raise exceptions on failure — no `Success` field to check:

| Exception | When |
|---|---|
| `EBinDistApiError` | Server returned a non-2xx response. Inspect `Code`, `StatusCode`, `RequestId`. |
| `EBinDistTransportError` | Network failure, timeout, or malformed response. |
| `EBinDistChecksumMismatch` | Downloaded file's SHA256 doesn't match. Inspect `Expected`, `Actual`. |

```pascal
try
  Client.DownloadFile('myapp', '1.0.0', OutputPath);
except
  on E: EBinDistChecksumMismatch do
    // Handle checksum mismatch
  on E: EBinDistApiError do
  begin
    if E.Code = 'not_found' then
      // Handle not found
    else if E.Code = 'unauthorized' then
      // Handle auth failure
    else
      // Handle other API errors
  end;
  on E: EBinDistTransportError do
    // Handle network errors
end;
```

Common `EBinDistApiError.Code` values: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `rate_limited`, `server_error`.

## Thread Safety

The client is thread-safe. A single `IBinDistClient` or `IBinDistAdmin` instance can be shared across threads. All per-request state (headers, options) is local to each call — no mutable fields are modified after construction.

## License

See [LICENSE](LICENSE).
