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

function Get-NotificationItems {
    param(
        [string]$RecipientId,
        [string]$Token
    )

    $response = Invoke-RestMethod `
        -Method Get `
        -Uri "$GatewayUrl/api/notifications?recipientId=$RecipientId" `
        -Headers @{ Authorization = "Bearer $Token" }
    if ($null -eq $response) {
        return @()
    }
    return @($response)
}

function Wait-ForNotificationType {
    param(
        [string]$RecipientId,
        [string]$Type,
        [string]$Token,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $items = @(Get-NotificationItems -RecipientId $RecipientId -Token $Token)
        $match = $items | Where-Object { $_.type -eq $Type } | Select-Object -First 1
        if ($match) {
            return $match
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Notification $Type was not persisted for recipient $RecipientId within $TimeoutSeconds seconds"
}

function Wait-ForNoNotifications {
    param(
        [string]$RecipientId,
        [string]$Token,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $items = @(Get-NotificationItems -RecipientId $RecipientId -Token $Token)
        if ($items.Count -eq 0) {
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Notifications for deleted user $RecipientId were not removed within $TimeoutSeconds seconds"
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
$demoSuffix = Get-Date -Format "yyyyMMddHHmmss"
$startAt = (Get-Date).AddDays(30).ToString("yyyy-MM-ddTHH:mm:ss")
$endAt = (Get-Date).AddDays(30).AddHours(4).ToString("yyyy-MM-ddTHH:mm:ss")

Write-Step 3 "Create users in the teammate-owned UserService"
$camperUserPayload = @{
    firstName = "Feign"
    lastName  = "Camper"
    email     = "feign.camper.$demoSuffix@campconnect.test"
    password  = "Demo123!"
    phone     = "21000001"
    role      = "CAMPER"
}
$waitlistUserPayload = @{
    firstName = "Rabbit"
    lastName  = "Waitlist"
    email     = "rabbit.waitlist.$demoSuffix@campconnect.test"
    password  = "Demo123!"
    phone     = "21000002"
    role      = "CAMPER"
}
$thirdUserPayload = @{
    firstName = "Async"
    lastName  = "Camper"
    email     = "async.camper.$demoSuffix@campconnect.test"
    password  = "Demo123!"
    phone     = "21000003"
    role      = "CAMPER"
}

$camperUser = (Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/users" `
    -ExpectedStatus 201 `
    -Token $adminToken `
    -Body $camperUserPayload).Json
$waitlistUser = (Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/users" `
    -ExpectedStatus 201 `
    -Token $adminToken `
    -Body $waitlistUserPayload).Json
$thirdUser = (Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/users" `
    -ExpectedStatus 201 `
    -Token $adminToken `
    -Body $thirdUserPayload).Json

$camperUserId = [string]$camperUser.id
$waitlistUserId = [string]$waitlistUser.id
$thirdUserId = [string]$thirdUser.id
Assert-True ($camperUserId -match "^[0-9]+$") "UserService returned a numeric camper ID"
Assert-True ($waitlistUserId -match "^[0-9]+$") "UserService returned a numeric waitlist ID"
Assert-True ($thirdUserId -match "^[0-9]+$") "UserService returned a numeric third participant ID"

Write-Step 4 "Prove asynchronous RabbitMQ USER_CREATED handling"
$welcomeNotification = Wait-ForNotificationType `
    -RecipientId $camperUserId `
    -Type "USER_WELCOME" `
    -Token $camperToken
Assert-True (
    $welcomeNotification.message -like "*Feign*"
) "Notification Service persisted a welcome notification from UserService's RabbitMQ event"

$rabbitQueues = docker exec campconnect-rabbitmq-1 rabbitmqctl list_queues name consumers
$rabbitQueueText = $rabbitQueues -join "`n"
Assert-True (
    $rabbitQueueText -match "campconnect.notification.user.created.queue"
) "Notification Service owns a dedicated user-created queue"
Assert-True (
    $rabbitQueueText -match "campconnect.notification.user.updated.queue"
) "Notification Service owns a dedicated user-updated queue"

$eventPayload = @{
    title            = "Defense Demo Event $demoStamp"
    description      = "A complete event lifecycle demonstration for the distributed web applications defense."
    category         = "WORKSHOP"
    startAt          = $startAt
    endAt            = $endAt
    location         = "ESPRIT Tunis"
    organizerId      = $waitlistUserId
    capacity         = 1
    waitlistCapacity = 2
    price            = 25.50
    published        = $true
}

Write-Step 5 "Prove centralized Gateway security"
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

Write-Step 6 "Create a published event as ORGANIZER"
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

Write-Step 7 "Demonstrate DTO validation and structured errors"
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

Write-Step 8 "Prove cross-member OpenFeign user validation"
$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 400 `
    -Token $camperToken `
    -Body @{ participantId = "not-a-user-id" }

$missingUserResponse = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 404 `
    -Token $camperToken `
    -Body @{ participantId = "999999999999999999" }
Assert-True (
    $missingUserResponse.Content -like "*Participant user not found*"
) "Event Service maps the teammate UserService 404 into a coherent registration error"

$confirmed = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $camperToken `
    -Body @{ participantId = $camperUserId }
Assert-True ($confirmed.Json.registrationStatus -eq "CONFIRMED") "First participant receives the available seat"
Assert-True (
    $confirmed.Content -like "*$camperUserId*"
) "A real teammate UserService user was accepted through OpenFeign"

$firstWaitlisted = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{ participantId = $waitlistUserId }
Assert-True ($firstWaitlisted.Json.registrationStatus -eq "WAITLISTED") "Second participant joins the waitlist"
Assert-True ($firstWaitlisted.Json.waitlistPosition -eq 1) "First waitlisted participant has position 1"

$secondWaitlisted = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 200 `
    -Token $adminToken `
    -Body @{ participantId = $thirdUserId }
Assert-True ($secondWaitlisted.Json.registrationStatus -eq "WAITLISTED") "Third participant joins the waitlist"
Assert-True ($secondWaitlisted.Json.waitlistPosition -eq 2) "Second waitlisted participant has position 2"

$null = Invoke-ExpectedApi `
    -Method Post `
    -Path "/api/events/$eventId/registrations" `
    -ExpectedStatus 409 `
    -Token $camperToken `
    -Body @{ participantId = $camperUserId }

$availability = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/events/$eventId/availability" `
    -ExpectedStatus 200
Assert-True ($availability.Json.registeredCount -eq 1) "Availability reports one confirmed registration"
Assert-True ($availability.Json.waitlistCount -eq 2) "Availability reports two waitlisted participants"
Assert-True ($availability.Json.fullyBooked -eq $true) "Availability reports the event as fully booked"

Write-Step 9 "Verify persisted registration notifications"
$camperNotifications = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications?recipientId=$camperUserId&eventId=$eventId" `
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

Write-Step 10 "Cancel a confirmed registration and promote the waitlist"
$afterCancellation = Invoke-ExpectedApi `
    -Method Delete `
    -Path "/api/events/$eventId/registrations/$camperUserId" `
    -ExpectedStatus 200 `
    -Token $camperToken

Assert-True (
    $afterCancellation.Json.participantIds -contains $waitlistUserId
) "First waitlisted participant was promoted automatically"
Assert-True (
    $afterCancellation.Json.waitlistParticipantIds -contains $thirdUserId
) "Second waitlisted participant remains in the waitlist"

$organizerNotifications = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications?recipientId=$waitlistUserId&eventId=$eventId" `
    -ExpectedStatus 200 `
    -Token $organizerToken
$organizerNotificationItems = @($organizerNotifications.Json)
Assert-True (
    $organizerNotificationItems.type -contains "WAITLIST_PROMOTED"
) "Promotion created a persisted WAITLIST_PROMOTED notification"

Write-Step 11 "Prove asynchronous RabbitMQ USER_UPDATED handling"
$updatedCamperPayload = @{
    firstName = "Feign"
    lastName  = "Camper Updated"
    email     = $camperUserPayload.email
    password  = "Demo123!"
    phone     = "21999999"
    role      = "CAMPER"
}
$null = Invoke-ExpectedApi `
    -Method Put `
    -Path "/api/users/$camperUserId" `
    -ExpectedStatus 200 `
    -Token $adminToken `
    -Body $updatedCamperPayload
$profileNotification = Wait-ForNotificationType `
    -RecipientId $camperUserId `
    -Type "USER_PROFILE_UPDATED" `
    -Token $camperToken
Assert-True (
    $profileNotification.title -eq "Profile updated"
) "Notification Service persisted the asynchronous user profile update"

Write-Step 12 "Demonstrate guarded event lifecycle behavior"
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

Write-Step 13 "Demonstrate persisted notification read state"
$unreadBefore = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications/recipient/$waitlistUserId/unread-count" `
    -ExpectedStatus 200 `
    -Token $organizerToken
Assert-True ($unreadBefore.Json.unreadCount -gt 0) "Organizer has unread notifications"

$markAll = Invoke-ExpectedApi `
    -Method Patch `
    -Path "/api/notifications/recipient/$waitlistUserId/read-all" `
    -ExpectedStatus 200 `
    -Token $organizerToken `
    -Body @{}
Assert-True ($markAll.Json.updatedCount -gt 0) "Mark-all-read updates persisted notifications"

$unreadAfter = Invoke-ExpectedApi `
    -Method Get `
    -Path "/api/notifications/recipient/$waitlistUserId/unread-count" `
    -ExpectedStatus 200 `
    -Token $organizerToken
Assert-True ($unreadAfter.Json.unreadCount -eq 0) "Unread count becomes zero"

Write-Step 14 "Prove notification write permissions"
$manualNotification = @{
    recipientId = $camperUserId
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

Write-Step 15 "Prove asynchronous RabbitMQ USER_DELETED cleanup"
$null = Invoke-ExpectedApi `
    -Method Delete `
    -Path "/api/users/$camperUserId" `
    -ExpectedStatus 204 `
    -Token $adminToken
Wait-ForNoNotifications -RecipientId $camperUserId -Token $camperToken
Assert-True ($true) "Deleting a teammate-owned user asynchronously removed that user's notifications"

if (-not $SkipMongoEvidence) {
    Write-Step 16 "Inspect MongoDB persistence directly"
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
Write-Host "User IDs used for Feign: $camperUserId, $waitlistUserId, $thirdUserId"
Write-Host "The event and remaining demo users stay persisted for Swagger and database inspection."
