unit BinDist.Factory;

interface

uses
  BinDist.Interfaces;

function CreateBinDistClient(const BaseUrl, ApiKey: string): IBinDistClient;
function CreateBinDistAdminClient(const BaseUrl, ApiKey: string): IBinDistAdmin;

implementation

uses
  BinDist.ClientV1, BinDist.AdminV1;

function CreateBinDistClient(const BaseUrl, ApiKey: string): IBinDistClient;
begin
  Result := TBinDistClientV1.Create(BaseUrl, ApiKey);
end;

function CreateBinDistAdminClient(const BaseUrl, ApiKey: string): IBinDistAdmin;
begin
  Result := TBinDistAdminV1.Create(BaseUrl, ApiKey);
end;

end.
