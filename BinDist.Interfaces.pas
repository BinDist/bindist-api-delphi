unit BinDist.Interfaces;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  // ---------------------------------------------------------------------------
  // Shared data records
  // ---------------------------------------------------------------------------

  TPagination = record
    Page: Integer;
    Limit: Integer;
    Total: Integer;
    HasNext: Boolean;
    HasPrevious: Boolean;
  end;

  TPaginatedResult<T> = record
    Items: T;
    Pagination: TPagination;
    RequestId: string;
  end;

  TApplicationInfo = record
    ApplicationId: string;
    Name: string;
    Description: string;
    IsActive: Boolean;
    CreatedAt: TDateTime;
    UpdatedAt: TDateTime;
    Tags: TArray<string>;
  end;

  TVersionInfo = record
    VersionId: string;
    ApplicationId: string;
    Version: string;
    ReleaseNotes: string;
    IsActive: Boolean;
    IsEnabled: Boolean;
    CreatedAt: TDateTime;
    UpdatedAt: TDateTime;
    FileSize: Int64;
    DownloadCount: Integer;
  end;

  TVersionFile = record
    FileId: string;
    FileName: string;
    FileType: string;
    FileSize: Int64;
    Checksum: string;
    Order: Integer;
    Description: string;
  end;

  TDownloadInfo = record
    DownloadId: string;
    Url: string;
    ExpiresAt: TDateTime;
    FileName: string;
    FileSize: Int64;
    Checksum: string;
  end;

  TShareLink = record
    ShareUrl: string;
    ExpiresAt: TDateTime;
  end;

  TStats = record
    TotalDownloads: Integer;
  end;

  // ---------------------------------------------------------------------------
  // Customer client options
  // ---------------------------------------------------------------------------

  TListApplicationsOptions = record
    Page: Integer;
    PageSize: Integer;
    Search: string;
    Tags: TArray<string>;
  end;

  TRequestOptions = record
    Channel: string;  // '' for production (default), 'Test' for test channel
  end;

  // ---------------------------------------------------------------------------
  // Customer client interface
  // ---------------------------------------------------------------------------

  IBinDistClient = interface
    ['{B2C3D4E5-F6A7-4890-BCDE-F01234567890}']

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

  // ---------------------------------------------------------------------------
  // Admin client types
  // ---------------------------------------------------------------------------

  TCreateApplicationOptions = record
    ApplicationId: string;
    Name: string;
    CustomerIds: TArray<string>;
    Description: string;
    Tags: TArray<string>;
  end;

  TUpdateVersionOptions = record
    IsEnabledSet: Boolean;
    IsEnabled: Boolean;
    IsActiveSet: Boolean;
    IsActive: Boolean;
    ReleaseNotesSet: Boolean;
    ReleaseNotes: string;
  end;

  TUpdateCustomerOptions = record
    NameSet: Boolean;
    Name: string;
    IsActiveSet: Boolean;
    IsActive: Boolean;
    NotesSet: Boolean;
    Notes: string;
  end;

  TCustomerInfo = record
    CustomerId: string;
    Name: string;
    ApiKey: string;
    IsActive: Boolean;
    Notes: string;
    CreatedAt: TDateTime;
  end;

  TCreateCustomerResult = record
    CustomerId: string;
    ApiKey: string;
    Name: string;
    CreatedAt: string;
  end;

  TUploadResult = record
    Message: string;
    VersionId: string;
    ApplicationId: string;
    Version: string;
    FileSize: Int64;
    Checksum: string;
  end;

  TActivityEntry = record
    ActivityType: string;
    ApplicationId: string;
    Version: string;
    CustomerId: string;
    Timestamp: TDateTime;
  end;

  // ---------------------------------------------------------------------------
  // Admin client interface
  // ---------------------------------------------------------------------------

  IBinDistAdmin = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF0123456789}']

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

end.
