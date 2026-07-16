#!/bin/bash
# mail_function.sh - Common email notification function

send_notification_email() {
    # Parameters
    local recipient="${1:-munnu@kolumbus.fi}"
    local subject="$2"
    local log_file="$3"      # Path to log file in /tmp
    local sender="${4:-noreply@norttilaakso.fi}"  # Default sender if not provided
    
    # Check if log file exists
    if [[ ! -f "$log_file" ]]; then
        echo "Error: Log file '$log_file' not found." >&2
        return 1
    fi
    
    # Convert subject and sender from UTF-8 to ISO-8859-15
    local subject_iso=$(echo "$subject" | iconv -f UTF-8 -t ISO-8859-15//TRANSLIT 2>/dev/null | base64 -w 0)
    local sender_iso=$(echo "$sender" | iconv -f UTF-8 -t ISO-8859-15//TRANSLIT 2>/dev/null)
    
    # If conversion failed, use original strings
    [[ -z "$subject_iso" ]] && subject_iso="$subject"
    [[ -z "$sender_iso" ]] && sender_iso="$sender"
    
    # Prepare a temporary file for the converted log content
    local temp_log_file=$(mktemp)
    
    # Convert log file content from UTF-8 to ISO-8859-15
    if ! iconv -f UTF-8 -t ISO-8859-15//TRANSLIT "$log_file" > "$temp_log_file" 2>/dev/null; then
        echo "Warning: Encoding conversion failed, using original log file." >&2
        cp "$log_file" "$temp_log_file"
    fi
    
    # Check which mail client is available
    if command -v mail >/dev/null 2>&1; then
        # Use mail if available
        mail -s "$subject" -r "$sender" "$recipient" < "$log_file"
        local mail_status=$?
    elif command -v sendmail >/dev/null 2>&1; then
        # Use sendmail if available
        {
            echo "From: $sender_iso"
            echo "To: $recipient"
            echo "Subject: $subject_iso"
            echo "Content-Type: text/plain; charset=ISO-8859-15"
            echo "MIME-Version: 1.0"
            echo ""
            cat "$temp_log_file"
        } | sendmail -t
        local mail_status=$?
    else
        echo "Error: No mail client (mail or sendmail) found on the system." >&2
        local mail_status=1
    fi
    
    # Clean up the temporary file
    rm -f "$temp_log_file"
    
    return $mail_status
}

# Only define functions if this script is sourced
# If run directly, show usage example
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced by other scripts."
    echo "Example usage:"
    echo "  source $(basename "$0")"
    echo "  send_notification_email recipient@example.com 'Subject' '/tmp/logfile.log' 'sender@example.com'"
    exit 1
fi
