[CmdletBinding()]
param(
    [string]$GatewayUrl = "http://localhost:9001",
    [string]$KeycloakUrl = "http://localhost:8180",
    [string]$ConfigServerUrl = "http://localhost:8099",
    [string]$EurekaUrl = "http://localhost:8761",
    [switch]$SkipMongoEvidence
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param(
        [int]$Number,
        [string]$Title
    )

    Write-Host ""
    Write-Host ("[{0:00}] {1}" -f $Number, $Title) -ForegroundColor Cyan
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }

    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Get-DemoToken {
    param(
        [string]$Username,
        [string]$Password
    )

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "$KeycloakUrl/realms/campconnect/protocol/openid-connect/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            client_id  = "campconnect-web"
            grant_type = "password"
            username   = $Username
            password   = $Password
        }

    return $response.access_token
}

function Get-JwtPayload {
    param([string]$Token)

    $payload = $Token.Split(".")[1].Replace("-", "+").Replace("_", "/")
    switch ($payload.Length % 4) {
        2 { $payload += "==" }
        3 { $payload += "=" }
    }

    $json = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($payload)
    )
    return $json | ConvertFrom-Json
}

function Invoke-ExpectedApi {
    param(
        [string]$Method,
        [string]$Path,
        [int]$ExpectedStatus,
        [string]$Token,
        $Body
    )

    $parameters = @{
        Method          = $Method
        Uri             = "$GatewayUrl$Path"
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }

    if ($Token) {
        $parameters.Headers = @{
            Authorization = "Bearer $Token"
        }
    }

    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 12
    }

    $status = 0
    $content = ""

    try {
        $response = Invoke-WebRequest @parameters
        $status = [int]$response.StatusCode
        $content = $response.Content
    }
    catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if (
            $_.ErrorDetails -and
            $_.ErrorDetails.PSObject.Properties.Name -contains "Message" -and
            $_.ErrorDetails.Message
        ) {
            $content = $_.ErrorDetails.Message
        }
        if (-not $content -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try {
                        $content = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            catch {
                $content = ""
            }
        }
    }

    if ($status -ne $ExpectedStatus) {
        throw "$Method $Path returned HTTP $status; expected $ExpectedStatus. Body: $content"
    }

    $json = $null
    if ($content) {
        try {
            $json = $content | ConvertFrom-Json
        }
        catch {
            $json = $null
        }
    }

    Write-Host "$Method $Path -> HTTP $status" -ForegroundColor DarkGreen
    return [pscustomobject]@{
        Status  = $status
        Content = $content
        Json    = $json
    }
}

Write-Host "CampConnect Events and Notifications showcase" -ForegroundColor Yellow
Write-Host "This script creates persistent demo data with a unique timestamp."

Write-Step 1 "Verify infrastructure, discovery, configuration, and OpenAPI"
$null = Invoke-ExpectedApi -Method Get -Path "/actuator/health" -ExpectedStatus 200

$eurekaResponse = Invoke-WebRequest -UseBasicParsing -Uri $EurekaUrl
Assert-True ($eurekaResponse.StatusCode -eq 200) "Eureka dashboard is reachable"

$eventConfig = Invoke-RestMethod -Uri "$ConfigServerUrl/event-service/default"
$notificationConfig = Invoke-RestMethod -Uri "$ConfigServerUrl/notification-service/default"
Assert-True ($eventConfig.name -eq "event-service") "Config Server exposes event-service configuration"
Assert-True ($notificationConfig.name -eq "notification-service") "Config Server exposes notification-service configuration"

$eventOpenApi = Invoke-RestMethod -Uri "$GatewayUrl/openapi/events"
$notificationOpenApi = Invoke-RestMethod -Uri "$GatewayUrl/openapi/notifications"
Assert-True ($eventOpenApi.info.title -like "*Event*") "Gateway exposes the Events OpenAPI document"
Assert-True ($notificationOpenApi.info.title -like "*Notification*") "Gateway exposes the Notifications OpenAPI document"

Write-Step 2 "Authenticate the three Keycloak demo roles"
$adminToken = Get-DemoToken -Username "camp-admin" -Password "Admin123!"
$organizerToken = Get-DemoToken -Username "organizer" -Password "Organizer123!"
$camperToken = Get-DemoToken -Username "camper" -Password "Camper123!"

$adminJwt = Get-JwtPayload -Token $adminToken
$organizerJwt = Get-JwtPayload -Token $organizerToken
$camperJwt = Get-JwtPayload -Token $camperToken

Assert-True ($adminJwt.realm_access.roles -contains "ADMIN") "camp-admin token contains ADMIN"
Assert-True ($organizerJwt.realm_access.roles -contains "ORGANIZER") "organizer token contains ORGANIZER"
Assert-True ($camperJwt.realm_access.roles -contains "USER") "camper token contains USER"

Write-Host "Admin subject:     $($adminJwt.sub)"
Write-Host "Organizer subject: $($organizerJwt.sub)"
Write-Host "Camper subject:    $($camperJwt.sub)"

$demoStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$startAt = (Get-Date).AddDays(30).ToString("yyyy-MM-ddTHH:mm:ss")
$endAt = (Get-Date).AddDays(30).AddHours(4).ToString("yyyy-MM-ddTHH:mm:ss")

$eventPayload = @{
    title            = "Defense Demo Event $demoStamp"
    description      = "A complete event lifecycle demonstration for the distributed web applications defense."
    category         = "WORKSHOP"
    startAt          = $startAt
    endAt            = $endAt
    location         = "ESPRIT Tunis"
    organizerId      = $organizerJwt.sub
    capacity         = 1
    waitlistCapacity = 2
    price            = 25.50
    published        = $true
}

Write-Step 3 "Prove centralized Gateway security"
$publicEvents = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/events?published=true" `
    -ExpectedStatus 200
Assert-True ($null -ne $publicEvents.Json) "Published event catalogue is public"

$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events" `
    -ExpectedStatus 401 `
    -Body $eventPayload

$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events" `
    -ExpectedStatus 403 `
    -Token $camperToken `
    -Body $eventPayload

$null = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications" `
    -ExpectedStatus 401

Write-Step 4 "Create a published event as ORGANIZER"
$createResponse = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events" `
    -ExpectedStatus 201 `
    -Token $organizerToken `
    -Body $eventPayload

$eventId = $createResponse.Json.id
Assert-True (-not [string]::IsNullOrWhiteSpace($eventId)) "Created event has a MongoDB identifier"
Assert-True ($createResponse.Json.status -eq "SCHEDULED") "Published event starts in SCHEDULED state"
Assert-True ($createResponse.Json.availableSeats -eq 1) "Computed availability starts at one seat"
Write-Host "Created event ID: $eventId" -ForegroundColor Yellow

Write-Step 5 "Demonstrate DTO validation and structured errors"
$invalidPayload = @{
    title            = ""
    description      = "short"
    category         = "WORKSHOP"
    startAt          = $startAt
    endAt            = $endAt
    location         = ""
    organizerId      = ""
    capacity         = 0
    waitlistCapacity = -1
    price            = -5
    published        = $true
}

$validationResponse = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events" `
    -ExpectedStatus 400 `
    -Token $organizerToken `
    -Body $invalidPayload

Assert-True ($validationResponse.Content -like "*validationErrors*") "Validation response contains field-level errors"

Write-Step 6 "Fill capacity and create an ordered waitlist"
$confirmed = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $camperToken `
    -Body @{ participantId = $camperJwt.sub }
Assert-True ($confirmed.Json.registrationStatus -eq "CONFIRMED") "First participant receives the available seat"

$firstWaitlisted = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{ participantId = $organizerJwt.sub }
Assert-True ($firstWaitlisted.Json.registrationStatus -eq "WAITLISTED") "Second participant joins the waitlist"
Assert-True ($firstWaitlisted.Json.waitlistPosition -eq 1) "First waitlisted participant has position 1"

$secondWaitlisted = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $adminToken `
    -Body @{ participantId = $adminJwt.sub }
Assert-True ($secondWaitlisted.Json.registrationStatus -eq "WAITLISTED") "Third participant joins the waitlist"
Assert-True ($secondWaitlisted.Json.waitlistPosition -eq 2) "Second waitlisted participant has position 2"

$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 409 `
    -Token $camperToken `
    -Body @{ participantId = $camperJwt.sub }

$availability = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/events/$eventId/availability" `
    -ExpectedStatus 200
Assert-True ($availability.Json.registeredCount -eq 1) "Availability reports one confirmed registration"
Assert-True ($availability.Json.waitlistCount -eq 2) "Availability reports two waitlisted participants"
Assert-True ($availability.Json.fullyBooked -eq $true) "Availability reports the event as fully booked"

Write-Step 7 "Prove synchronous Feign notification creation"
$camperNotifications = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications?recipientId=$($camperJwt.sub)&eventId=$eventId" `
    -ExpectedStatus 200 `
    -Token $camperToken
$camperNotificationItems = @($camperNotifications.Json)
Assert-True (
    $camperNotificationItems.type -contains "REGISTRATION_CONFIRMED"
) "Registration created a persisted REGISTRATION_CONFIRMED notification"

$combined = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/events/with-notification" `
    -ExpectedStatus 200 `
    -Token $organizerToken
Assert-True ($null -ne $combined.Json.events) "Feign aggregation returns event data"
Assert-True ($null -ne $combined.Json.notifications) "Feign aggregation returns notification data"

Write-Step 8 "Cancel a confirmed registration and promote the waitlist"
$afterCancellation = Invoke-ExpectedApi `
    -Method Delete `
    -Path "/api/events/$eventId/registrations/$($camperJwt.sub)" `
    -ExpectedStatus 200 `
    -Token $camperToken

Assert-True (
    $afterCancellation.Json.participantIds -contains $organizerJwt.sub
) "First waitlisted participant was promoted automatically"
Assert-True (
    $afterCancellation.Json.waitlistParticipantIds -contains $adminJwt.sub
) "Second waitlisted participant remains in the waitlist"

$organizerNotifications = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications?recipientId=$($organizerJwt.sub)&eventId=$eventId" `
    -ExpectedStatus 200 `
    -Token $organizerToken
$organizerNotificationItems = @($organizerNotifications.Json)
Assert-True (
    $organizerNotificationItems.type -contains "WAITLIST_PROMOTED"
) "Promotion created a persisted WAITLIST_PROMOTED notification"

Write-Step 9 "Demonstrate guarded event lifecycle behavior"
$null = Invoke-ExpectedApi `
    -Method Delete `
    -Path "/api/events/$eventId" `
    -ExpectedStatus 409 `
    -Token $organizerToken

$postponedStart = (Get-Date).AddDays(35).ToString("yyyy-MM-ddTHH:mm:ss")
$postponedEnd = (Get-Date).AddDays(35).AddHours(5).ToString("yyyy-MM-ddTHH:mm:ss")
$postponed = Invoke-ExpectedApi `
    -Method Patch `
    -Path "/api/events/$eventId/postpone" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{
        startAt = $postponedStart
        endAt   = $postponedEnd
    }
Assert-True ($postponed.Json.status -eq "POSTPONED") "Postponement changes status to POSTPONED"

$cancelled = Invoke-ExpectedApi `
    -Method Patch `
    -Path "/api/events/$eventId/cancel" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{ reason = "Defense demonstration completed" }
Assert-True ($cancelled.Json.status -eq "CANCELLED") "Cancellation changes status to CANCELLED"
Assert-True ($cancelled.Json.published -eq $false) "Cancelled event is automatically unpublished"

Write-Step 10 "Demonstrate persisted notification read state"
$unreadBefore = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications/recipient/$($organizerJwt.sub)/unread-count" `
    -ExpectedStatus 200 `
    -Token $organizerToken
Assert-True ($unreadBefore.Json.unreadCount -gt 0) "Organizer has unread notifications"

$markAll = Invoke-ExpectedApi `
    -Method Patch `
    -Path "/api/notifications/recipient/$($organizerJwt.sub)/read-all" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{}
Assert-True ($markAll.Json.updatedCount -gt 0) "Mark-all-read updates persisted notifications"

$unreadAfter = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications/recipient/$($organizerJwt.sub)/unread-count" `
    -ExpectedStatus 200 `
    -Token $organizerToken
Assert-True ($unreadAfter.Json.unreadCount -eq 0) "Unread count becomes zero"

Write-Step 11 "Prove notification write permissions"
$manualNotification = @{
    recipientId = $camperJwt.sub
    eventId     = $eventId
    type        = "GENERAL"
    title       = "Manual defense notification"
    message     = "This request demonstrates notification CRUD permissions."
    actionUrl   = "/events/$eventId"
}

$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/notifications" `
    -ExpectedStatus 403 `
    -Token $camperToken `
    -Body $manualNotification

$createdNotification = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/notifications" `
    -ExpectedStatus 201 `
    -Token $organizerToken `
    -Body $manualNotification
Assert-True (
    $createdNotification.Json.type -eq "GENERAL"
) "ORGANIZER can create a persisted notification"

if (-not $SkipMongoEvidence) {
    Write-Step 12 "Inspect MongoDB persistence directly"
    $eventCount = docker exec campconnect-event-mongodb-1 mongosh --quiet --eval `
        "db.getSiblingDB('event_db').events.countDocuments({_id: ObjectId('$eventId')})"
    $notificationCount = docker exec campconnect-notification-mongodb-1 mongosh --quiet --eval `
        "db.getSiblingDB('notification_db').notifications.countDocuments({eventId: '$eventId'})"

    Assert-True ([int]$eventCount -eq 1) "Event document exists in event_db"
    Assert-True ([int]$notificationCount -gt 0) "Notification documents exist in notification_db"
}

Write-Host ""
Write-Host "SHOWCASE COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Event ID: $eventId"
Write-Host "Event title: $($eventPayload.title)"
Write-Host "The demo data remains persisted for Swagger, Postman, and MongoDB inspection."
