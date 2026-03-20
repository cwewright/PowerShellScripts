<#
.SYNOPSIS
    Retrieves department/org-level data from UKG via the SOAP BIDataService
    and writes unique departments to a Dataverse table.

.DESCRIPTION
    Uses the UKG SOAP BIDataService (https://service4.ultipro.com/services/BIDataService).
    This requires a BI report to be pre-configured in UKG that includes the
    employee fields listed in the data template.

    Flow: LogOn → GetReportList → ExecuteReport → poll GetReportByKey → parse CSV.

    NOTE: The REST API script (Get-UKGDepartments-REST.ps1) is recommended
    over this approach unless you specifically need the full employee dataset.

    Designed for Azure Automation (PowerShell 7.1 runtime).

.NOTES
    Required Azure Automation Variables:
      - UKG_Username
      - UKG_Password         (encrypted)
      - UKG_CustomerKey       (encrypted) — aka Customer API Key
      - UKG_ServiceUrl        e.g. https://service4.ultipro.com/services/BIDataService
      - UKG_BIServiceToken   (encrypted) — BI Service token
      - UKG_ServiceID         — The BI report service/path ID
      - UKG_InstanceKey       (encrypted)
      - UKG_ClientAccessKey   (encrypted)
      - Dataverse_TenantId
      - Dataverse_ClientId
      - Dataverse_ClientSecret (encrypted)
      - Dataverse_EnvironmentUrl  e.g. https://yourorg.crm.dynamics.com

    Pre-requisite:
      - A BI report must exist in UKG containing these columns (in order):
        FirstName, LastName, EmailAddress, DOB, (blank), EmployeeStatus,
        EmployeeNumber, HireDate, DateOfLastHire, FullTimeOrPartTime,
        FullOrPartTimeCode, WorkLocationCode, Division, Department, JobTitle,
        AlternateJobTitle, OrgLevel1Code, OrgLevel2Code, OrgLevel3Code,
        OrgLevel4Code, SupervisorName, CareerCounselor, IsPeopleManager,
        Gender, Grade
#>

# -------------------------------------------------------------------
# 1. CONFIGURATION
# -------------------------------------------------------------------
$ukgUsername       = Get-AutomationVariable -Name 'UKG_Username'
$ukgPassword       = Get-AutomationVariable -Name 'UKG_Password'
$ukgCustomerKey    = Get-AutomationVariable -Name 'UKG_CustomerKey'
$ukgServiceUrl     = Get-AutomationVariable -Name 'UKG_ServiceUrl'
$ukgToken          = Get-AutomationVariable -Name 'UKG_BIServiceToken'
$ukgInstanceKey    = Get-AutomationVariable -Name 'UKG_InstanceKey'
$ukgClientAccessKey = Get-AutomationVariable -Name 'UKG_ClientAccessKey'

$dataverseTenantId     = Get-AutomationVariable -Name 'Dataverse_TenantId'
$dataverseClientId     = Get-AutomationVariable -Name 'Dataverse_ClientId'
$dataverseClientSecret = Get-AutomationVariable -Name 'Dataverse_ClientSecret'
$dataverseUrl          = Get-AutomationVariable -Name 'Dataverse_EnvironmentUrl'

# Dataverse table config — adjust prefix to match your environment
$dataverseTable            = 'cr_ukgdepartments'
$colName                   = 'cr_name'
$colOrgLevelCode           = 'cr_orglevelcode'
$colOrgLevelDescription    = 'cr_orgleveldescription'
$colOrgLevelNumber         = 'cr_orglevelnumber'

# -------------------------------------------------------------------
# 2. SOAP HELPER — Build XML envelope
# -------------------------------------------------------------------
function New-SoapEnvelope {
    param([string]$Body)
    @"
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:bis="http://www.ultipro.com/dataservices/bidata/2">
  <soap:Header>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
  </soap:Header>
  <soap:Body>
    $Body
  </soap:Body>
</soap:Envelope>
"@
}

function Invoke-UKGSoap {
    param(
        [string]$Action,
        [string]$Body
    )
    $envelope = New-SoapEnvelope -Body $Body
    $headers = @{
        'SOAPAction'   = "http://www.ultipro.com/dataservices/bidata/2/IBIDataService/$Action"
        'Content-Type' = 'text/xml; charset=utf-8'
    }
    $response = Invoke-WebRequest -Uri $ukgServiceUrl -Method POST `
        -Headers $headers -Body $envelope -UseBasicParsing
    [xml]$response.Content
}

# -------------------------------------------------------------------
# 3. LOG ON TO BI DATA SERVICE
# -------------------------------------------------------------------
Write-Output "Logging on to UKG BI Data Service..."

$logOnBody = @"
<bis:LogOn>
  <bis:logOnRequest>
    <bis:UserName>$ukgUsername</bis:UserName>
    <bis:Password>$ukgPassword</bis:Password>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
    <bis:UserAccessKey>$ukgToken</bis:UserAccessKey>
  </bis:logOnRequest>
</bis:LogOn>
"@

$logOnXml = Invoke-UKGSoap -Action 'LogOn' -Body $logOnBody
$ns = @{ bis = 'http://www.ultipro.com/dataservices/bidata/2' }
$logOnResult = $logOnXml | Select-Xml -XPath '//bis:LogOnResult' -Namespace $ns
$token = ($logOnResult.Node).Token
$instanceKey = ($logOnResult.Node).InstanceKey

if (-not $token) {
    throw "UKG LogOn failed. Check credentials."
}
Write-Output "UKG LogOn successful."

# -------------------------------------------------------------------
# 4. GET REPORT LIST (to find the correct report path)
# -------------------------------------------------------------------
Write-Output "Retrieving report list..."

$reportListBody = @"
<bis:GetReportList>
  <bis:context>
    <bis:ServiceId>$ukgInstanceKey</bis:ServiceId>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
    <bis:Token>$token</bis:Token>
    <bis:InstanceKey>$instanceKey</bis:InstanceKey>
  </bis:context>
</bis:GetReportList>
"@

$reportListXml = Invoke-UKGSoap -Action 'GetReportList' -Body $reportListBody
$reports = $reportListXml | Select-Xml -XPath '//bis:ReportItem' -Namespace $ns

Write-Output "Available reports:"
foreach ($report in $reports) {
    Write-Output "  - $($report.Node.ReportName) | Path: $($report.Node.ReportPath)"
}

# Set your report path here — update this to match your BI report
$reportPath = $reports[0].Node.ReportPath
Write-Output "Using report: $reportPath"

# -------------------------------------------------------------------
# 5. EXECUTE REPORT
# -------------------------------------------------------------------
Write-Output "Executing BI report..."

$executeBody = @"
<bis:ExecuteReport>
  <bis:reportRequest>
    <bis:ReportPath>$reportPath</bis:ReportPath>
  </bis:reportRequest>
  <bis:context>
    <bis:ServiceId>$ukgInstanceKey</bis:ServiceId>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
    <bis:Token>$token</bis:Token>
    <bis:InstanceKey>$instanceKey</bis:InstanceKey>
  </bis:context>
</bis:ExecuteReport>
"@

$executeXml = Invoke-UKGSoap -Action 'ExecuteReport' -Body $executeBody
$reportKey = ($executeXml | Select-Xml -XPath '//bis:ReportKey' -Namespace $ns).Node.InnerText

if (-not $reportKey) {
    throw "Failed to execute report. Check report path and permissions."
}
Write-Output "Report queued. Key: $reportKey"

# -------------------------------------------------------------------
# 6. POLL FOR REPORT COMPLETION AND RETRIEVE DATA
# -------------------------------------------------------------------
Write-Output "Polling for report completion..."

$reportReady = $false
$maxAttempts = 30
$attempt = 0

while (-not $reportReady -and $attempt -lt $maxAttempts) {
    Start-Sleep -Seconds 10
    $attempt++

    $retrieveBody = @"
<bis:GetReportByKey>
  <bis:reportKey>$reportKey</bis:reportKey>
  <bis:context>
    <bis:ServiceId>$ukgInstanceKey</bis:ServiceId>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
    <bis:Token>$token</bis:Token>
    <bis:InstanceKey>$instanceKey</bis:InstanceKey>
  </bis:context>
</bis:GetReportByKey>
"@

    $reportXml = Invoke-UKGSoap -Action 'GetReportByKey' -Body $retrieveBody
    $status = ($reportXml | Select-Xml -XPath '//bis:Status' -Namespace $ns).Node.InnerText

    Write-Output "  Attempt $attempt/$maxAttempts — Status: $status"

    if ($status -eq 'Completed') {
        $reportReady = $true
    }
    elseif ($status -eq 'Failed') {
        throw "Report execution failed."
    }
}

if (-not $reportReady) {
    throw "Report did not complete within $($maxAttempts * 10) seconds."
}

# -------------------------------------------------------------------
# 7. PARSE CSV REPORT DATA
# -------------------------------------------------------------------
Write-Output "Parsing report data..."

$reportStream = ($reportXml | Select-Xml -XPath '//bis:ReportStream' -Namespace $ns).Node.InnerText
$csvBytes = [Convert]::FromBase64String($reportStream)
$csvText = [Text.Encoding]::UTF8.GetString($csvBytes)
$csvLines = $csvText -split "`n" | Where-Object { $_.Trim() -ne '' }

# Skip header row
$allEmployees = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($i = 1; $i -lt $csvLines.Count; $i++) {
    $rawData = $csvLines[$i] -split ','

    # Guard against short rows
    if ($rawData.Count -lt 25) { continue }

    $allEmployees.Add([PSCustomObject]@{
        FirstName          = $rawData[0]
        LastName           = $rawData[1]
        EmailAddress       = $rawData[2].Trim()
        DOB                = $rawData[3].Trim()
        EmployeeStatus     = $rawData[5]
        EmployeeNumber     = $rawData[6].Trim()
        HireDate           = $rawData[7]
        DateOfLastHire     = $rawData[8]
        FullTimeOrPartTime = $rawData[9]
        FullOrPartTimeCode = $rawData[10]
        WorkLocationCode   = $rawData[11]
        Division           = $rawData[12]
        Department         = $rawData[13]
        JobTitle           = $rawData[14]
        AlternateJobTitle  = $rawData[15]
        OrgLevel1Code      = $rawData[16]
        OrgLevel2Code      = $rawData[17]
        OrgLevel3Code      = $rawData[18]
        OrgLevel4Code      = $rawData[19]
        SupervisorName     = $rawData[20]
        CareerCounselor    = $rawData[21]
        IsPeopleManager    = if ($rawData[22]) { $rawData[22].Trim() } else { '' }
        Gender             = $rawData[23]
        Grade              = $rawData[24]
    })
}

Write-Output "Parsed $($allEmployees.Count) employee records."

# -------------------------------------------------------------------
# 8. EXTRACT UNIQUE DEPARTMENTS (OrgLevel 1-4)
# -------------------------------------------------------------------
$uniqueDepts = [System.Collections.Generic.List[PSCustomObject]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()

foreach ($emp in $allEmployees) {
    for ($level = 1; $level -le 4; $level++) {
        $code = $emp."OrgLevel${level}Code"
        if ([string]::IsNullOrWhiteSpace($code)) { continue }

        $key = "$level|$code"
        if ($seen.Add($key)) {
            $uniqueDepts.Add([PSCustomObject]@{
                OrgLevelNumber      = $level
                OrgLevelCode        = $code.Trim()
                OrgLevelDescription = $code.Trim()  # SOAP CSV may not include descriptions separately
            })
        }
    }
}

Write-Output "Found $($uniqueDepts.Count) unique org level entries."

# -------------------------------------------------------------------
# 9. AUTHENTICATE TO DATAVERSE
# -------------------------------------------------------------------
Write-Output "Authenticating to Dataverse..."

$tokenBody = @{
    grant_type    = 'client_credentials'
    client_id     = $dataverseClientId
    client_secret = $dataverseClientSecret
    scope         = "$dataverseUrl/.default"
}

$tokenResponse = Invoke-RestMethod `
    -Uri "https://login.microsoftonline.com/$dataverseTenantId/oauth2/v2.0/token" `
    -Method POST -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'

$dvToken = $tokenResponse.access_token
if (-not $dvToken) {
    throw "Failed to authenticate to Dataverse."
}

$dvHeaders = @{
    'Authorization'    = "Bearer $dvToken"
    'Content-Type'     = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    'Prefer'           = 'return=representation'
}

Write-Output "Dataverse authentication successful."

# -------------------------------------------------------------------
# 10. FETCH EXISTING RECORDS TO AVOID DUPLICATES
# -------------------------------------------------------------------
Write-Output "Fetching existing Dataverse records..."

$existingRecords = [System.Collections.Generic.HashSet[string]]::new()
$dvFetchUrl = "$dataverseUrl/api/data/v9.2/${dataverseTable}s?`$select=$colOrgLevelCode,$colOrgLevelNumber"

do {
    $dvResponse = Invoke-RestMethod -Uri $dvFetchUrl -Method GET -Headers $dvHeaders
    foreach ($record in $dvResponse.value) {
        $key = "$($record.$colOrgLevelNumber)|$($record.$colOrgLevelCode)"
        $null = $existingRecords.Add($key)
    }
    $dvFetchUrl = $dvResponse.'@odata.nextLink'
} while ($dvFetchUrl)

Write-Output "Found $($existingRecords.Count) existing records in Dataverse."

# -------------------------------------------------------------------
# 11. WRITE UNIQUE DEPARTMENTS TO DATAVERSE
# -------------------------------------------------------------------
$created = 0
$skipped = 0

foreach ($dept in $uniqueDepts) {
    $key = "$($dept.OrgLevelNumber)|$($dept.OrgLevelCode)"

    if ($existingRecords.Contains($key)) {
        $skipped++
        continue
    }

    $body = @{
        $colName                = "$($dept.OrgLevelDescription) (L$($dept.OrgLevelNumber))"
        $colOrgLevelCode        = $dept.OrgLevelCode
        $colOrgLevelDescription = $dept.OrgLevelDescription
        $colOrgLevelNumber      = [int]$dept.OrgLevelNumber
    } | ConvertTo-Json

    try {
        $null = Invoke-RestMethod `
            -Uri "$dataverseUrl/api/data/v9.2/${dataverseTable}s" `
            -Method POST -Headers $dvHeaders -Body $body
        $created++
    }
    catch {
        Write-Warning "Failed to create record for $($dept.OrgLevelCode) L$($dept.OrgLevelNumber): $($_.Exception.Message)"
    }
}

Write-Output "Done. Created: $created | Skipped (already exist): $skipped"

# -------------------------------------------------------------------
# 12. LOG OFF FROM UKG
# -------------------------------------------------------------------
try {
    $logOffBody = @"
<bis:LogOff>
  <bis:context>
    <bis:ServiceId>$ukgInstanceKey</bis:ServiceId>
    <bis:ClientAccessKey>$ukgClientAccessKey</bis:ClientAccessKey>
    <bis:Token>$token</bis:Token>
    <bis:InstanceKey>$instanceKey</bis:InstanceKey>
  </bis:context>
</bis:LogOff>
"@
    Invoke-UKGSoap -Action 'LogOff' -Body $logOffBody | Out-Null
    Write-Output "UKG session closed."
}
catch {
    Write-Warning "Could not cleanly log off UKG: $($_.Exception.Message)"
}
