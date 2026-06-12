param(
    [string]$RealmFile = "..\keycloak\campconnect-realm.json",
    [string]$UserServiceUrl = "http://localhost:8110/api/users"
)

$ErrorActionPreference = "Stop"

Write-Host "Syncing Keycloak Users to Java UserService..."

$realmData = Get-Content $RealmFile | ConvertFrom-Json
$users = $realmData.users

foreach ($user in $users) {
    Write-Host "Checking user: $($user.email)..." -NoNewline
    
    # Map Keycloak role to Java enum
    $javaRole = "CAMPER" # Default
    if ($user.realmRoles -contains "ADMIN") {
        $javaRole = "ADMIN"
    } elseif ($user.realmRoles -contains "ORGANIZER") {
        $javaRole = "ORGANIZER"
    } elseif ($user.realmRoles -contains "SITE_OWNER") {
        $javaRole = "SITE_OWNER"
    }

    # Grab the first password if present
    $password = "Password123!"
    if ($user.credentials.Count -gt 0) {
        $password = $user.credentials[0].value
    }
    
    # Ensure password meets Java backend requirement of minimum 6 characters
    if ($password.Length -lt 6) {
        $password = $password + "123"
    }

    # Construct request payload
    $body = @{
        firstName = $user.firstName
        lastName  = $user.lastName
        email     = $user.email
        password  = $password
        phone     = "12345678" # Default required by regex
        role      = $javaRole
    }

    # First check if user exists
    $userExists = $false
    try {
        $check = Invoke-RestMethod -Uri "$UserServiceUrl/email/$($user.email)" -ErrorAction Stop
        $userExists = $true
    } catch {
        # 404 means it doesn't exist, which is what we expect for new users
    }

    if ($userExists) {
        Write-Host " Already exists. Skipping." -ForegroundColor Yellow
    } else {
        try {
            $jsonBody = $body | ConvertTo-Json
            Invoke-RestMethod -Uri $UserServiceUrl -Method Post -ContentType "application/json" -Body $jsonBody | Out-Null
            Write-Host " Successfully Created! (Role: $javaRole)" -ForegroundColor Green
        } catch {
            Write-Host " Failed to create!" -ForegroundColor Red
            Write-Host $_.Exception.Message
        }
    }
}

Write-Host "Sync Complete!" -ForegroundColor Cyan
