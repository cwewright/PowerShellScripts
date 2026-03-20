<#
.SYNOPSIS
    Retrieves all OrgLevel (1-4) departments from UKG Pro REST API and writes
    unique departments to a Dataverse table.

.DESCRIPTION
    Uses the UKG Pro REST API (personnel/v1/org-levels) instead of the SOAP
    BIDataService. The REST API is purpose-built for org-level lookups and
    avoids the complexity of BI report configuration and CSV parsing.

    Designed for Azure Automation (PowerShell 7.1 runtime).

.NOTES
    Required Azure Automation Variables (encrypted where noted):
      - UKG_CustomerApiKey   (encrypted)
      - UKG_Username
      - UKG_Password         (encrypted)
      - UKG_BaseUrl           e.g. https://service4.ultipro.com
      - Dataverse_TenantId
      - Dataverse_ClientId
      - Dataverse_ClientSecret (encrypted)
      - Dataverse_EnvironmentUrl  e.g. https://yourorg.crm.dynamics.com

    Required Dataverse Table:
      - Table: cr_ukgdepartments (or your prefix)
      - Columns: cr_name, cr_orglevelcode, cr_orgleveldescription, cr_orglevelnumber
#>

# -------------------------------------------------------------------
# 1. CONFIGURATION — Pull from Azure Automation variables
# -------------------------------------------------------------------
$ukgBaseUrl       = Get-AutomationVariable -Name 'UKG_BaseUrl'           # e.g. https://service4.ultipro.com
$customerApiKey   = Get-AutomationVariable -Name 'UKG_CustomerApiKey'
$ukgUsername      = Get-AutomationVariable -Name 'UKG_Username'
$ukgPassword      = Get-AutomationVariable -Name 'UKG_Password'

$dataverseTenantId     = Get-AutomationVariable -Name 'Dataverse_TenantId'
$dataverseClientId     = Get-AutomationVariable -Name 'Dataverse_ClientId'
$dataverseClientSecret = Get-AutomationVariable -Name 'Dataverse_ClientSecret'
$dataverseUrl          = Get-AutomationVariable -Name 'Dataverse_EnvironmentUrl'  # e.g. https://yourorg.crm.dynamics.com

# Dataverse table/column configuration — adjust the schema name prefix to match yours
$dataverseTable            = 'cr_ukgdepartments'
$colName                   = 'cr_name'
$colOrgLevelCode           = 'cr_orglevelcode'
$colOrgLevelDescription    = 'cr_orgleveldescription'
$colOrgLevelNumber         = 'cr_orglevelnumber'

# -------------------------------------------------------------------
# 2. BUILD UKG PRO REST API HEADERS
# -------------------------------------------------------------------
# UKG Pro REST API authenticates per-request via headers:
#   - US-Customer-Api-Key: your customer API key
#   - Authorization: Usr {username}:{password}
# No login/logout endpoints — credentials are sent on every call.
# -------------------------------------------------------------------

$apiHeaders = @{
    'US-Customer-Api-Key' = $customerApiKey
    'Authorization'       = "Usr $($ukgUsername):$($ukgPassword)"
    'Content-Type'        = 'application/json'
}

Write-Output "UKG API headers configured."

# -------------------------------------------------------------------
# 3. RETRIEVE ORG LEVELS 1-4
# -------------------------------------------------------------------
# GET /personnel/v1/org-levels returns all org levels.
# Each org level entry has: orgLevelCode, orgLevelDescription, orgLevelNumber
#
# We page through results using the 'page' query parameter.
# -------------------------------------------------------------------

$allOrgLevels = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($level in 1..4) {
    Write-Output "Fetching OrgLevel $level..."
    $page = 1
    $hasMore = $true

    while ($hasMore) {
        $uri = "$ukgBaseUrl/personnel/v1/org-levels?orgLevelNumber=$level&page=$page&per_page=200"

        try {
            $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $apiHeaders
        }
        catch {
            Write-Warning "Error fetching OrgLevel $level page $page : $($_.Exception.Message)"
            break
        }

        if ($response -and $response.Count -gt 0) {
            foreach ($item in $response) {
                $allOrgLevels.Add([PSCustomObject]@{
                    OrgLevelNumber      = $level
                    OrgLevelCode        = $item.orgLevelCode
                    OrgLevelDescription = $item.orgLevelDescription
                })
            }
            $page++
            # If we got fewer results than per_page, we've hit the last page
            if ($response.Count -lt 200) { $hasMore = $false }
        }
        else {
            $hasMore = $false
        }
    }
}

Write-Output "Retrieved $($allOrgLevels.Count) total org level entries across levels 1-4."

# -------------------------------------------------------------------
# 4. DEDUPLICATE
# -------------------------------------------------------------------
# Unique by combination of OrgLevelNumber + OrgLevelCode
# -------------------------------------------------------------------

$uniqueDepts = $allOrgLevels |
    Sort-Object OrgLevelNumber, OrgLevelCode -Unique

Write-Output "Found $($uniqueDepts.Count) unique departments."

# -------------------------------------------------------------------
# 5. AUTHENTICATE TO DATAVERSE
# -------------------------------------------------------------------
# Uses OAuth2 client credentials flow with an App Registration.
# Make sure the App Registration has the Dataverse "user_impersonation"
# permission or an application user in Dataverse with appropriate role.
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
    throw "Failed to authenticate to Dataverse. Check App Registration credentials."
}

$dvHeaders = @{
    'Authorization' = "Bearer $dvToken"
    'Content-Type'  = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    'Prefer'           = 'return=representation'
}

Write-Output "Dataverse authentication successful."

# -------------------------------------------------------------------
# 6. FETCH EXISTING RECORDS TO AVOID DUPLICATES
# -------------------------------------------------------------------
# Pull all existing records from Dataverse to compare.
# For large tables, you could use a $filter instead.
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
# 7. UPSERT UNIQUE DEPARTMENTS TO DATAVERSE
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

# No logout needed — UKG REST API is stateless (per-request auth).
