#!/bin/bash

#######################################################################
# YouTrack Knowledge Base Downloader
#
# SYNOPSIS
#     Downloads the complete YouTrack Knowledge Base including all 
#     articles, sub-articles, comments, and attachments.
#
# DESCRIPTION
#     This script connects to the YouTrack API and downloads all articles 
#     from the knowledge base. It preserves the folder structure with 
#     articles and sub-articles, embeds comments into markdown files,
#     and downloads all attachments alongside each article.
#     All output is logged to both console and a log file.
#
# NOTES
#     Author: Viorel Ghiurca
#     Version: 1.2.0
#     Date: 2025-11-27
#
# DEPENDENCIES
#     - curl
#     - jq (JSON processor)
#######################################################################

set -e

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Global variables
LOG_FILE=""
BASE_URL=""
API_BASE_URL=""
TOKEN=""
OUTPUT_PATH=""

#######################################################################
# Logging Functions
#######################################################################

write_log() {
    local message="$1"
    local level="${2:-Info}"
    
    # Determine console color based on level
    local color=""
    case "$level" in
        "Info")    color="$WHITE" ;;
        "Success") color="$GREEN" ;;
        "Warning") color="$YELLOW" ;;
        "Error")   color="$RED" ;;
        "Header")  color="$CYAN" ;;
        "Detail")  color="$GRAY" ;;
        *)         color="$WHITE" ;;
    esac
    
    # Write to console
    echo -e "${color}${message}${NC}"
    
    # Write to log file if path is set (skip empty messages in log)
    if [[ -n "$LOG_FILE" && -n "$message" ]]; then
        local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        local log_level=$(printf "%-7s" "${level^^}")
        echo "[$timestamp] [$log_level] $message" >> "$LOG_FILE"
    fi
}

initialize_log_file() {
    local output_path="$1"
    local timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
    LOG_FILE="${output_path}/download_${timestamp}.log"
    
    # Create initial log entry
    cat > "$LOG_FILE" << EOF
================================================================================
  YouTrack Knowledge Base Download Log
  Author: Viorel Ghiurca
  Started: $(date "+%Y-%m-%d %H:%M:%S")
================================================================================

EOF
}

#######################################################################
# Helper Functions
#######################################################################

invoke_youtrack_api() {
    local endpoint="$1"
    local uri="${API_BASE_URL}${endpoint}"
    
    local response
    local http_code
    
    # Make API call and capture both response and HTTP status code
    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$uri" 2>/dev/null)
    
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    case "$http_code" in
        200)
            echo "$response"
            return 0
            ;;
        404)
            write_log "  Warning: Resource not found - $endpoint" "Warning"
            return 1
            ;;
        401)
            write_log "Error: Unauthorized. Please check your token!" "Error"
            exit 1
            ;;
        *)
            write_log "  API Error ($http_code): $endpoint" "Warning"
            return 1
            ;;
    esac
}

get_safe_filename() {
    local name="$1"
    local max_length="${2:-50}"
    
    # Remove invalid characters and replace with underscore
    local safe_name=$(echo "$name" | sed 's/[<>:"/\\|?*]/_/g')
    
    # Remove multiple consecutive underscores
    safe_name=$(echo "$safe_name" | sed 's/_\+/_/g')
    
    # Trim underscores from start and end
    safe_name=$(echo "$safe_name" | sed 's/^_//;s/_$//')
    
    # Limit length
    if [[ ${#safe_name} -gt $max_length ]]; then
        safe_name="${safe_name:0:$max_length}"
        # Remove trailing underscore if present
        safe_name=$(echo "$safe_name" | sed 's/_$//')
    fi
    
    echo "$safe_name"
}

convert_unix_timestamp() {
    local timestamp="$1"
    
    if [[ -z "$timestamp" || "$timestamp" == "null" || "$timestamp" == "0" ]]; then
        echo "Unknown"
        return
    fi
    
    # Convert milliseconds to seconds
    local seconds=$((timestamp / 1000))
    
    # Format the date
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        date -r "$seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown"
    else
        # Linux
        date -d "@$seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown"
    fi
}

download_attachment() {
    local url="$1"
    local destination_path="$2"
    
    # Handle relative URLs - prepend base URL if needed
    local download_url="$url"
    if [[ ! "$url" =~ ^https?:// ]]; then
        # Remove leading slash if present to avoid double slashes
        local relative_path="${url#/}"
        download_url="${BASE_URL}/${relative_path}"
    fi
    
    # Create directory if it doesn't exist
    local directory=$(dirname "$destination_path")
    mkdir -p "$directory"
    
    # Download the file
    if curl -s -H "Authorization: Bearer $TOKEN" -o "$destination_path" "$download_url" 2>/dev/null; then
        return 0
    else
        write_log "    Download error: Failed to download $url" "Warning"
        return 1
    fi
}

get_article_comments() {
    local article_id="$1"
    local fields="id,author(id,name),text,created,visibility(permittedGroups(id,name),permittedUsers(id,name))"
    local endpoint="/articles/${article_id}/comments?fields=${fields}"
    
    invoke_youtrack_api "$endpoint"
}

get_article_attachments() {
    local article_id="$1"
    local fields="id,name,author(id,name),created,updated,size,mimeType,extension,url"
    local endpoint="/articles/${article_id}/attachments?fields=${fields}"
    
    invoke_youtrack_api "$endpoint"
}

get_child_articles() {
    local article_id="$1"
    local fields="id,summary,idReadable"
    local endpoint="/articles/${article_id}/childArticles?fields=${fields}"
    
    invoke_youtrack_api "$endpoint"
}

get_article_details() {
    local article_id="$1"
    local fields="hasStar,content,created,updated,id,idReadable,reporter(name),summary,project(shortName),parentArticle(id,idReadable,summary)"
    local endpoint="/articles/${article_id}?fields=${fields}"
    
    invoke_youtrack_api "$endpoint"
}

create_article_markdown() {
    local article_json="$1"
    local comments_json="$2"
    local attachments_json="$3"
    
    local summary=$(echo "$article_json" | jq -r '.summary // "Untitled"')
    local id_readable=$(echo "$article_json" | jq -r '.idReadable // "Unknown"')
    local project=$(echo "$article_json" | jq -r '.project.shortName // "Unknown"')
    local reporter=$(echo "$article_json" | jq -r '.reporter.name // "Unknown"')
    local created=$(echo "$article_json" | jq -r '.created // 0')
    local updated=$(echo "$article_json" | jq -r '.updated // 0')
    local content=$(echo "$article_json" | jq -r '.content // ""')
    local parent_id=$(echo "$article_json" | jq -r '.parentArticle.idReadable // ""')
    local parent_summary=$(echo "$article_json" | jq -r '.parentArticle.summary // ""')
    
    local markdown=""
    
    # Title
    markdown+="# ${summary}\n\n"
    
    # Metadata
    markdown+="## Metadata\n\n"
    markdown+="| Property | Value |\n"
    markdown+="|----------|-------|\n"
    markdown+="| **ID** | ${id_readable} |\n"
    markdown+="| **Project** | ${project} |\n"
    
    if [[ "$reporter" != "Unknown" && "$reporter" != "null" ]]; then
        markdown+="| **Author** | ${reporter} |\n"
    fi
    
    markdown+="| **Created** | $(convert_unix_timestamp "$created") |\n"
    markdown+="| **Updated** | $(convert_unix_timestamp "$updated") |\n"
    
    if [[ -n "$parent_id" && "$parent_id" != "null" ]]; then
        markdown+="| **Parent Article** | ${parent_id} - ${parent_summary} |\n"
    fi
    
    markdown+="\n"
    
    # Content
    markdown+="## Content\n\n"
    
    if [[ -n "$content" && "$content" != "null" ]]; then
        markdown+="${content}\n"
    else
        markdown+="*No content available*\n"
    fi
    
    markdown+="\n"
    
    # Attachments section
    if [[ -n "$attachments_json" && "$attachments_json" != "[]" && "$attachments_json" != "null" ]]; then
        local attachment_count=$(echo "$attachments_json" | jq 'length')
        
        if [[ $attachment_count -gt 0 ]]; then
            markdown+="## Attachments\n\n"
            
            for i in $(seq 0 $((attachment_count - 1))); do
                local att_name=$(echo "$attachments_json" | jq -r ".[$i].name // \"Unknown\"")
                local att_size=$(echo "$attachments_json" | jq -r ".[$i].size // 0")
                local att_author=$(echo "$attachments_json" | jq -r ".[$i].author.name // \"Unknown\"")
                local att_created=$(echo "$attachments_json" | jq -r ".[$i].created // 0")
                
                # Convert size to KB
                local att_size_kb=$(echo "scale=2; $att_size / 1024" | bc 2>/dev/null || echo "0")
                
                markdown+="- **${att_name}** (${att_size_kb} KB)\n"
                markdown+="  - Author: ${att_author}\n"
                markdown+="  - Created: $(convert_unix_timestamp "$att_created")\n"
                markdown+="  - File: [attachments/${att_name}](attachments/${att_name})\n\n"
            done
        fi
    fi
    
    # Comments section
    if [[ -n "$comments_json" && "$comments_json" != "[]" && "$comments_json" != "null" ]]; then
        local comment_count=$(echo "$comments_json" | jq 'length')
        
        if [[ $comment_count -gt 0 ]]; then
            markdown+="## Comments\n\n"
            
            for i in $(seq 0 $((comment_count - 1))); do
                local comment_author=$(echo "$comments_json" | jq -r ".[$i].author.name // \"Unknown\"")
                local comment_created=$(echo "$comments_json" | jq -r ".[$i].created // 0")
                local comment_text=$(echo "$comments_json" | jq -r ".[$i].text // \"\"")
                
                local comment_num=$((i + 1))
                markdown+="### Comment ${comment_num} - ${comment_author} ($(convert_unix_timestamp "$comment_created"))\n\n"
                
                if [[ -n "$comment_text" && "$comment_text" != "null" ]]; then
                    markdown+="${comment_text}\n"
                else
                    markdown+="*No text*\n"
                fi
                
                markdown+="\n---\n\n"
            done
        fi
    fi
    
    echo -e "$markdown"
}

process_article() {
    local article_id="$1"
    local article_id_readable="$2"
    local parent_path="$3"
    local depth="${4:-0}"
    
    # Create indent for logging
    local indent=""
    for ((i=0; i<depth; i++)); do
        indent+="  "
    done
    
    # Get full article details
    local article_details
    article_details=$(get_article_details "$article_id") || {
        write_log "${indent}Skipping article: ${article_id_readable}" "Warning"
        return
    }
    
    if [[ -z "$article_details" || "$article_details" == "null" ]]; then
        write_log "${indent}Skipping article: ${article_id_readable}" "Warning"
        return
    fi
    
    local id_readable=$(echo "$article_details" | jq -r '.idReadable // "Unknown"')
    local summary=$(echo "$article_details" | jq -r '.summary // "Untitled"')
    
    # Create folder name - use only article ID to avoid path length limits
    local folder_name="$id_readable"
    local article_path="${parent_path}/${folder_name}"
    
    write_log "${indent}Processing: ${id_readable} - ${summary}" "Info"
    
    # Create article directory
    mkdir -p "$article_path"
    
    # Get comments
    local comments=""
    comments=$(get_article_comments "$article_id") || comments="[]"
    
    if [[ -n "$comments" && "$comments" != "[]" && "$comments" != "null" ]]; then
        local comment_count=$(echo "$comments" | jq 'length')
        if [[ $comment_count -gt 0 ]]; then
            write_log "${indent}  Found: ${comment_count} comment(s)" "Detail"
        fi
    fi
    
    # Get attachments
    local attachments=""
    attachments=$(get_article_attachments "$article_id") || attachments="[]"
    
    # Download attachments
    if [[ -n "$attachments" && "$attachments" != "[]" && "$attachments" != "null" ]]; then
        local attachment_count=$(echo "$attachments" | jq 'length')
        
        if [[ $attachment_count -gt 0 ]]; then
            write_log "${indent}  Downloading ${attachment_count} attachment(s)..." "Detail"
            
            local attachments_path="${article_path}/attachments"
            mkdir -p "$attachments_path"
            
            for i in $(seq 0 $((attachment_count - 1))); do
                local att_name=$(echo "$attachments" | jq -r ".[$i].name // \"unknown\"")
                local att_url=$(echo "$attachments" | jq -r ".[$i].url // \"\"")
                
                local safe_filename=$(get_safe_filename "$att_name")
                local att_file_path="${attachments_path}/${safe_filename}"
                
                if [[ -n "$att_url" && "$att_url" != "null" ]]; then
                    if download_attachment "$att_url" "$att_file_path"; then
                        write_log "${indent}    ✓ ${safe_filename}" "Detail"
                    fi
                fi
            done
        fi
    fi
    
    # Create markdown file
    local markdown_content
    markdown_content=$(create_article_markdown "$article_details" "$comments" "$attachments")
    local markdown_file_path="${article_path}/README.md"
    
    echo -e "$markdown_content" > "$markdown_file_path"
    write_log "${indent}  ✓ Markdown created" "Detail"
    
    # Process child articles recursively
    local child_articles=""
    child_articles=$(get_child_articles "$article_id") || child_articles="[]"
    
    if [[ -n "$child_articles" && "$child_articles" != "[]" && "$child_articles" != "null" ]]; then
        local child_count=$(echo "$child_articles" | jq 'length')
        
        if [[ $child_count -gt 0 ]]; then
            write_log "${indent}  Processing ${child_count} sub-article(s)..." "Header"
            
            for i in $(seq 0 $((child_count - 1))); do
                local child_id=$(echo "$child_articles" | jq -r ".[$i].id")
                local child_id_readable=$(echo "$child_articles" | jq -r ".[$i].idReadable")
                
                process_article "$child_id" "$child_id_readable" "$article_path" $((depth + 1))
            done
        fi
    fi
}

#######################################################################
# Main Script
#######################################################################

main() {
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  YouTrack Knowledge Base Downloader${NC}"
    echo -e "${CYAN}  Viorel Ghiurca${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    
    # Check dependencies
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required but not installed.${NC}"
        echo "Please install jq: sudo apt-get install jq (Linux) or brew install jq (macOS)"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Error: curl is required but not installed.${NC}"
        exit 1
    fi
    
    # Get Base URL
    read -p "Please enter the YouTrack Base URL (e.g. https://youtrack.example.com): " BASE_URL
    BASE_URL="${BASE_URL%/}"  # Remove trailing slash
    
    # Get output path
    read -p "Please enter the output path (e.g. /home/user/YouTrack-Export): " OUTPUT_PATH
    
    # Get permanent token
    echo ""
    echo -e "${YELLOW}Please enter your Permanent Token (e.g. perm:username.token.secret)${NC}"
    read -p "Token: " TOKEN
    
    # Validate inputs
    if [[ -z "$BASE_URL" ]]; then
        echo -e "${RED}Error: Base URL cannot be empty!${NC}"
        exit 1
    fi
    
    if [[ -z "$OUTPUT_PATH" ]]; then
        echo -e "${RED}Error: Output path cannot be empty!${NC}"
        exit 1
    fi
    
    if [[ -z "$TOKEN" ]]; then
        echo -e "${RED}Error: Token cannot be empty!${NC}"
        exit 1
    fi
    
    # Create output directory if it doesn't exist
    if [[ ! -d "$OUTPUT_PATH" ]]; then
        mkdir -p "$OUTPUT_PATH"
        echo -e "${GREEN}Output directory created: ${OUTPUT_PATH}${NC}"
    fi
    
    # Initialize log file
    initialize_log_file "$OUTPUT_PATH"
    write_log "Log file initialized: $LOG_FILE" "Success"
    
    # Set API base URL
    API_BASE_URL="${BASE_URL}/api"
    
    # Log configuration (without token for security)
    write_log "Configuration:" "Info"
    write_log "  Base URL: $BASE_URL" "Detail"
    write_log "  API URL: $API_BASE_URL" "Detail"
    write_log "  Output path: $OUTPUT_PATH" "Detail"
    
    write_log "" "Info"
    write_log "Starting YouTrack Knowledge Base download..." "Success"
    write_log "API URL: $API_BASE_URL" "Detail"
    write_log "Output path: $OUTPUT_PATH" "Detail"
    write_log "" "Info"
    
    # Test API connection
    write_log "Testing API connection..." "Warning"
    
    local test_result
    test_result=$(invoke_youtrack_api "/users/me?fields=id,name") || {
        write_log "Error: Connection failed. Please check URL and token!" "Error"
        exit 1
    }
    
    local user_name=$(echo "$test_result" | jq -r '.name // "Unknown"')
    write_log "Connection successful! Logged in as: ${user_name}" "Success"
    
    write_log "" "Info"
    
    # Get all articles with pagination
    write_log "Loading article list..." "Warning"
    local fields="hasStar,content,created,updated,id,idReadable,reporter(name),summary,project(shortName),parentArticle(id,idReadable)"
    
    local all_articles="[]"
    local skip=0
    local top=100
    
    while true; do
        local endpoint="/articles?fields=${fields}&\$skip=${skip}&\$top=${top}"
        local articles
        articles=$(invoke_youtrack_api "$endpoint") || break
        
        if [[ -z "$articles" || "$articles" == "[]" || "$articles" == "null" ]]; then
            break
        fi
        
        local count=$(echo "$articles" | jq 'length')
        
        if [[ $count -eq 0 ]]; then
            break
        fi
        
        # Merge arrays
        all_articles=$(echo "$all_articles $articles" | jq -s 'add')
        skip=$((skip + count))
        
        local total=$(echo "$all_articles" | jq 'length')
        write_log "  Loaded: ${total} articles..." "Detail"
        
        if [[ $count -lt $top ]]; then
            break
        fi
    done
    
    local total_articles=$(echo "$all_articles" | jq 'length')
    write_log "Found: ${total_articles} articles total" "Success"
    write_log "" "Info"
    
    # Filter to get only root articles (articles without parent)
    local root_articles=$(echo "$all_articles" | jq '[.[] | select(.parentArticle == null)]')
    local root_count=$(echo "$root_articles" | jq 'length')
    write_log "Of which ${root_count} are root articles (no parent)" "Success"
    write_log "" "Info"
    
    # Group by project
    local projects=$(echo "$root_articles" | jq -r '[.[].project.shortName] | unique | .[]')
    local project_count=$(echo "$projects" | wc -l | tr -d ' ')
    
    write_log "Projects found: ${project_count}" "Success"
    
    while IFS= read -r project; do
        local count=$(echo "$root_articles" | jq "[.[] | select(.project.shortName == \"$project\")] | length")
        write_log "  - ${project}: ${count} articles" "Detail"
    done <<< "$projects"
    
    write_log "" "Info"
    
    # Process each project
    while IFS= read -r project_name; do
        if [[ -z "$project_name" ]]; then
            project_name="Unknown"
        fi
        
        local project_path="${OUTPUT_PATH}/${project_name}"
        
        write_log "========================================" "Header"
        write_log "Project: ${project_name}" "Header"
        write_log "========================================" "Header"
        
        # Create project directory
        mkdir -p "$project_path"
        
        # Get articles for this project
        local project_articles=$(echo "$root_articles" | jq "[.[] | select(.project.shortName == \"$project_name\")]")
        local article_count=$(echo "$project_articles" | jq 'length')
        
        # Process each root article in this project
        for i in $(seq 0 $((article_count - 1))); do
            local article_id=$(echo "$project_articles" | jq -r ".[$i].id")
            local article_id_readable=$(echo "$project_articles" | jq -r ".[$i].idReadable")
            
            process_article "$article_id" "$article_id_readable" "$project_path" 0
        done
        
        write_log "" "Info"
    done <<< "$projects"
    
    # Log summary
    local end_time=$(date "+%Y-%m-%d %H:%M:%S")
    write_log "========================================" "Success"
    write_log "Download completed!" "Success"
    write_log "Output path: $OUTPUT_PATH" "Success"
    write_log "Log file: $LOG_FILE" "Success"
    write_log "Finished: ${end_time}" "Success"
    write_log "========================================" "Success"
}

# Run main function
main "$@"

