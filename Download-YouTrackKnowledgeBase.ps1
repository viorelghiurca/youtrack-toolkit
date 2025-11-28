<#
.SYNOPSIS
    Downloads the complete YouTrack Knowledge Base including all articles, sub-articles, comments, and attachments.

.DESCRIPTION
    This script connects to the YouTrack API and downloads all articles from the knowledge base.
    It preserves the folder structure with articles and sub-articles, embeds comments into markdown files,
    and downloads all attachments alongside each article.
    All output is logged to both console and a log file.

.NOTES
    Author: Viorel Ghiurca
    Version: 1.2.0
    Date: 2025-11-27
#>

# Set strict mode for better error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Logging Configuration

# Script-level variable for log file path (will be set after user input)
$script:LogFilePath = $null

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to both console and log file.
    #>
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message = "",
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Success", "Warning", "Error", "Header", "Detail")]
        [string]$Level = "Info",
        
        [Parameter(Mandatory = $false)]
        [switch]$NoNewLine
    )
    
    # Determine console color based on level
    $color = switch ($Level) {
        "Info"    { "White" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Header"  { "Cyan" }
        "Detail"  { "Gray" }
        default   { "White" }
    }
    
    # Write to console
    if ($NoNewLine) {
        Write-Host $Message -ForegroundColor $color -NoNewline
    }
    else {
        Write-Host $Message -ForegroundColor $color
    }
    
    # Write to log file if path is set (skip empty messages in log)
    if ($script:LogFilePath -and $Message -ne "") {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logLevel = $Level.ToUpper().PadRight(7)
        $logMessage = "[$timestamp] [$logLevel] $Message"
        Add-Content -Path $script:LogFilePath -Value $logMessage -Encoding UTF8
    }
}

function Initialize-LogFile {
    <#
    .SYNOPSIS
        Initializes the log file in the output directory.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $script:LogFilePath = Join-Path -Path $OutputPath -ChildPath "download_$timestamp.log"
    
    # Create initial log entry
    $header = @"
================================================================================
  YouTrack Knowledge Base Download Log
  Author: Viorel Ghiurca
  Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================

"@
    
    Set-Content -Path $script:LogFilePath -Value $header -Encoding UTF8
}

#endregion

#region User Input
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  YouTrack Knowledge Base Downloader" -ForegroundColor Cyan
Write-Host "  Viorel Ghiurca" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Get Base URL
$baseUrl = Read-Host -Prompt "Please enter the YouTrack Base URL (e.g. https://youtrack.example.com)"
$baseUrl = $baseUrl.TrimEnd('/')

# Get output path
$outputPath = Read-Host -Prompt "Please enter the output path (e.g. C:\YouTrack-Export)"

# Get permanent token
Write-Host ""
Write-Host "Please enter your Permanent Token (e.g. perm:username.token.secret)" -ForegroundColor Yellow
$token = Read-Host -Prompt "Token"

# Validate inputs
if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    Write-Host "Error: Base URL cannot be empty!" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($outputPath)) {
    Write-Host "Error: Output path cannot be empty!" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "Error: Token cannot be empty!" -ForegroundColor Red
    exit 1
}

# Create output directory if it doesn't exist
if (-not (Test-Path -Path $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    Write-Host "Output directory created: $outputPath" -ForegroundColor Green
}

# Initialize log file
Initialize-LogFile -OutputPath $outputPath
Write-Log -Message "Log file initialized: $script:LogFilePath" -Level "Success"

#endregion

#region API Configuration
$apiBaseUrl = "$baseUrl/api"
$headers = @{
    "Authorization" = "Bearer $token"
    "Accept" = "application/json"
    "Content-Type" = "application/json"
}

# Log configuration (without token for security)
Write-Log -Message "Configuration:" -Level "Info"
Write-Log -Message "  Base URL: $baseUrl" -Level "Detail"
Write-Log -Message "  API URL: $apiBaseUrl" -Level "Detail"
Write-Log -Message "  Output path: $outputPath" -Level "Detail"
#endregion

#region Helper Functions

function Invoke-YouTrackApi {
    <#
    .SYNOPSIS
        Invokes the YouTrack API with proper error handling.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $false)]
        [string]$Method = "GET"
    )
    
    $uri = "$apiBaseUrl$Endpoint"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.Exception.Message
        
        if ($statusCode -eq 404) {
            Write-Log -Message "  Warning: Resource not found - $Endpoint" -Level "Warning"
            return $null
        }
        elseif ($statusCode -eq 401) {
            Write-Log -Message "Error: Unauthorized. Please check your token!" -Level "Error"
            throw
        }
        else {
            Write-Log -Message "  API Error ($statusCode): $errorMessage" -Level "Warning"
            return $null
        }
    }
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Creates a safe file name by removing invalid characters.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 50
    )
    
    $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
    $regex = "[{0}]" -f [Regex]::Escape($invalidChars)
    $safeName = [Regex]::Replace($Name, $regex, '_')
    
    # Remove multiple consecutive underscores
    $safeName = [Regex]::Replace($safeName, '_+', '_')
    
    # Trim underscores from start and end
    $safeName = $safeName.Trim('_')
    
    # Limit length to avoid path too long errors on Windows
    if ($safeName.Length -gt $MaxLength) {
        $safeName = $safeName.Substring(0, $MaxLength).TrimEnd('_')
    }
    
    return $safeName
}

function Convert-UnixTimestamp {
    <#
    .SYNOPSIS
        Converts Unix timestamp (milliseconds) to DateTime string.
    #>
    param (
        [Parameter(Mandatory = $false)]
        [long]$Timestamp
    )
    
    if ($Timestamp -eq 0 -or $null -eq $Timestamp) {
        return "Unknown"
    }
    
    try {
        $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $dateTime = $epoch.AddMilliseconds($Timestamp).ToLocalTime()
        return $dateTime.ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return "Unknown"
    }
}

function Download-Attachment {
    <#
    .SYNOPSIS
        Downloads an attachment from YouTrack.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    
    try {
        # Handle relative URLs - prepend base URL if needed
        $downloadUrl = $Url
        if (-not $Url.StartsWith("http://") -and -not $Url.StartsWith("https://")) {
            # Remove leading slash if present to avoid double slashes
            $relativePath = $Url.TrimStart('/')
            $downloadUrl = "$baseUrl/$relativePath"
        }
        
        # Create directory if it doesn't exist
        $directory = Split-Path -Path $DestinationPath -Parent
        if (-not (Test-Path -Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        
        # Download the file
        Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $DestinationPath -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log -Message "    Download error: $($_.Exception.Message)" -Level "Warning"
        return $false
    }
}

function Get-ArticleComments {
    <#
    .SYNOPSIS
        Gets all comments for an article.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArticleId
    )
    
    $fields = "id,author(id,name),text,created,visibility(permittedGroups(id,name),permittedUsers(id,name))"
    $endpoint = "/articles/$ArticleId/comments?fields=$fields"
    
    $comments = Invoke-YouTrackApi -Endpoint $endpoint
    return $comments
}

function Get-ArticleAttachments {
    <#
    .SYNOPSIS
        Gets all attachments for an article.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArticleId
    )
    
    $fields = "id,name,author(id,name),created,updated,size,mimeType,extension,url"
    $endpoint = "/articles/$ArticleId/attachments?fields=$fields"
    
    $attachments = Invoke-YouTrackApi -Endpoint $endpoint
    return $attachments
}

function Get-ChildArticles {
    <#
    .SYNOPSIS
        Gets all child articles for a parent article.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArticleId
    )
    
    $fields = "id,summary,idReadable"
    $endpoint = "/articles/$ArticleId/childArticles?fields=$fields"
    
    $children = Invoke-YouTrackApi -Endpoint $endpoint
    return $children
}

function Get-ArticleDetails {
    <#
    .SYNOPSIS
        Gets detailed information for a specific article.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArticleId
    )
    
    $fields = "hasStar,content,created,updated,id,idReadable,reporter(name),summary,project(shortName),parentArticle(id,idReadable,summary)"
    $endpoint = "/articles/$ArticleId`?fields=$fields"
    
    $article = Invoke-YouTrackApi -Endpoint $endpoint
    return $article
}

function Create-ArticleMarkdown {
    <#
    .SYNOPSIS
        Creates a markdown file for an article including comments.
    #>
    param (
        [Parameter(Mandatory = $true)]
        $Article,
        
        [Parameter(Mandatory = $false)]
        $Comments,
        
        [Parameter(Mandatory = $false)]
        $Attachments
    )
    
    $markdown = @()
    
    # Title
    $markdown += "# $($Article.summary)"
    $markdown += ""
    
    # Metadata
    $markdown += "## Metadata"
    $markdown += ""
    $markdown += "| Property | Value |"
    $markdown += "|----------|-------|"
    $markdown += "| **ID** | $($Article.idReadable) |"
    $markdown += "| **Project** | $($Article.project.shortName) |"
    
    if ($Article.reporter) {
        $markdown += "| **Author** | $($Article.reporter.name) |"
    }
    
    $markdown += "| **Created** | $(Convert-UnixTimestamp -Timestamp $Article.created) |"
    $markdown += "| **Updated** | $(Convert-UnixTimestamp -Timestamp $Article.updated) |"
    
    if ($Article.parentArticle) {
        $markdown += "| **Parent Article** | $($Article.parentArticle.idReadable) - $($Article.parentArticle.summary) |"
    }
    
    $markdown += ""
    
    # Content
    $markdown += "## Content"
    $markdown += ""
    
    if ($Article.content) {
        $markdown += $Article.content
    }
    else {
        $markdown += "*No content available*"
    }
    
    $markdown += ""
    
    # Attachments section
    if ($Attachments -and $Attachments.Count -gt 0) {
        $markdown += "## Attachments"
        $markdown += ""
        
        foreach ($attachment in $Attachments) {
            $attachmentName = $attachment.name
            $attachmentSize = if ($attachment.size) { [math]::Round($attachment.size / 1024, 2) } else { 0 }
            $attachmentAuthor = if ($attachment.author) { $attachment.author.name } else { "Unknown" }
            $attachmentCreated = Convert-UnixTimestamp -Timestamp $attachment.created
            
            $markdown += "- **$attachmentName** (${attachmentSize} KB)"
            $markdown += "  - Author: $attachmentAuthor"
            $markdown += "  - Created: $attachmentCreated"
            $markdown += "  - File: [attachments/$attachmentName](attachments/$attachmentName)"
            $markdown += ""
        }
    }
    
    # Comments section
    if ($Comments -and $Comments.Count -gt 0) {
        $markdown += "## Comments"
        $markdown += ""
        
        $commentIndex = 1
        foreach ($comment in $Comments) {
            $authorName = if ($comment.author) { $comment.author.name } else { "Unknown" }
            $commentDate = Convert-UnixTimestamp -Timestamp $comment.created
            
            $markdown += "### Comment $commentIndex - $authorName ($commentDate)"
            $markdown += ""
            
            if ($comment.text) {
                $markdown += $comment.text
            }
            else {
                $markdown += "*No text*"
            }
            
            $markdown += ""
            $markdown += "---"
            $markdown += ""
            
            $commentIndex++
        }
    }
    
    return $markdown -join "`n"
}

function Process-Article {
    <#
    .SYNOPSIS
        Processes a single article: downloads content, comments, attachments, and child articles.
    #>
    param (
        [Parameter(Mandatory = $true)]
        $Article,
        
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        
        [Parameter(Mandatory = $false)]
        [int]$Depth = 0
    )
    
    $indent = "  " * $Depth
    
    # Get full article details
    $articleDetails = Get-ArticleDetails -ArticleId $Article.id
    
    if (-not $articleDetails) {
        Write-Log -Message "${indent}Skipping article: $($Article.idReadable)" -Level "Warning"
        return
    }
    
    # Create folder name - use only article ID to avoid Windows path length limits
    # The full title is preserved in the README.md file
    $folderName = $articleDetails.idReadable
    $articlePath = Join-Path -Path $ParentPath -ChildPath $folderName
    
    Write-Log -Message "${indent}Processing: $($articleDetails.idReadable) - $($articleDetails.summary)" -Level "Info"
    
    # Create article directory
    if (-not (Test-Path -Path $articlePath)) {
        New-Item -ItemType Directory -Path $articlePath -Force | Out-Null
    }
    
    # Get comments
    $comments = Get-ArticleComments -ArticleId $articleDetails.id
    if ($comments -and $comments.Count -gt 0) {
        Write-Log -Message "${indent}  Found: $($comments.Count) comment(s)" -Level "Detail"
    }
    
    # Get attachments
    $attachments = Get-ArticleAttachments -ArticleId $articleDetails.id
    
    # Download attachments
    if ($attachments -and $attachments.Count -gt 0) {
        Write-Log -Message "${indent}  Downloading $($attachments.Count) attachment(s)..." -Level "Detail"
        
        $attachmentsPath = Join-Path -Path $articlePath -ChildPath "attachments"
        if (-not (Test-Path -Path $attachmentsPath)) {
            New-Item -ItemType Directory -Path $attachmentsPath -Force | Out-Null
        }
        
        foreach ($attachment in $attachments) {
            $attachmentFileName = Get-SafeFileName -Name $attachment.name
            $attachmentFilePath = Join-Path -Path $attachmentsPath -ChildPath $attachmentFileName
            
            if ($attachment.url) {
                $downloaded = Download-Attachment -Url $attachment.url -DestinationPath $attachmentFilePath
                if ($downloaded) {
                    Write-Log -Message "${indent}    ✓ $attachmentFileName" -Level "Detail"
                }
            }
        }
    }
    
    # Create markdown file
    $markdownContent = Create-ArticleMarkdown -Article $articleDetails -Comments $comments -Attachments $attachments
    $markdownFileName = "README.md"
    $markdownFilePath = Join-Path -Path $articlePath -ChildPath $markdownFileName
    
    $markdownContent | Out-File -FilePath $markdownFilePath -Encoding UTF8 -Force
    Write-Log -Message "${indent}  ✓ Markdown created" -Level "Detail"
    
    # Process child articles recursively
    $childArticles = Get-ChildArticles -ArticleId $articleDetails.id
    
    if ($childArticles -and $childArticles.Count -gt 0) {
        Write-Log -Message "${indent}  Processing $($childArticles.Count) sub-article(s)..." -Level "Header"
        
        foreach ($childArticle in $childArticles) {
            Process-Article -Article $childArticle -ParentPath $articlePath -Depth ($Depth + 1)
        }
    }
}

#endregion

#region Main Script

Write-Log -Message "" -Level "Info"
Write-Log -Message "Starting YouTrack Knowledge Base download..." -Level "Success"
Write-Log -Message "API URL: $apiBaseUrl" -Level "Detail"
Write-Log -Message "Output path: $outputPath" -Level "Detail"
Write-Log -Message "" -Level "Info"

# Test API connection
Write-Log -Message "Testing API connection..." -Level "Warning"
try {
    $testResult = Invoke-YouTrackApi -Endpoint "/users/me?fields=id,name"
    if ($testResult) {
        Write-Log -Message "Connection successful! Logged in as: $($testResult.name)" -Level "Success"
    }
}
catch {
    Write-Log -Message "Error: Connection failed. Please check URL and token!" -Level "Error"
    exit 1
}

Write-Log -Message "" -Level "Info"

# Get all articles
Write-Log -Message "Loading article list..." -Level "Warning"
$fields = "hasStar,content,created,updated,id,idReadable,reporter(name),summary,project(shortName),parentArticle(id,idReadable)"

# YouTrack API uses pagination, we need to handle it
$allArticles = @()
$skip = 0
$top = 100  # Number of articles per page

do {
    $endpoint = "/articles?fields=$fields&`$skip=$skip&`$top=$top"
    $articles = Invoke-YouTrackApi -Endpoint $endpoint
    
    if ($articles -and $articles.Count -gt 0) {
        $allArticles += $articles
        $skip += $articles.Count
        Write-Log -Message "  Loaded: $($allArticles.Count) articles..." -Level "Detail"
    }
} while ($articles -and $articles.Count -eq $top)

Write-Log -Message "Found: $($allArticles.Count) articles total" -Level "Success"
Write-Log -Message "" -Level "Info"

# Filter to get only root articles (articles without parent)
$rootArticles = $allArticles | Where-Object { -not $_.parentArticle }
Write-Log -Message "Of which $($rootArticles.Count) are root articles (no parent)" -Level "Success"
Write-Log -Message "" -Level "Info"

# Group by project
$projectGroups = $rootArticles | Group-Object -Property { $_.project.shortName }

Write-Log -Message "Projects found: $($projectGroups.Count)" -Level "Success"
foreach ($group in $projectGroups) {
    Write-Log -Message "  - $($group.Name): $($group.Count) articles" -Level "Detail"
}
Write-Log -Message "" -Level "Info"

# Process each project
foreach ($projectGroup in $projectGroups) {
    $projectName = if ($projectGroup.Name) { $projectGroup.Name } else { "Unknown" }
    $projectPath = Join-Path -Path $outputPath -ChildPath $projectName
    
    Write-Log -Message "========================================" -Level "Header"
    Write-Log -Message "Project: $projectName" -Level "Header"
    Write-Log -Message "========================================" -Level "Header"
    
    # Create project directory
    if (-not (Test-Path -Path $projectPath)) {
        New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
    }
    
    # Process each root article in this project
    foreach ($article in $projectGroup.Group) {
        Process-Article -Article $article -ParentPath $projectPath -Depth 0
    }
    
    Write-Log -Message "" -Level "Info"
}

# Log summary
$endTime = Get-Date
Write-Log -Message "========================================" -Level "Success"
Write-Log -Message "Download completed!" -Level "Success"
Write-Log -Message "Output path: $outputPath" -Level "Success"
Write-Log -Message "Log file: $script:LogFilePath" -Level "Success"
Write-Log -Message "Finished: $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "Success"
Write-Log -Message "========================================" -Level "Success"

#endregion
