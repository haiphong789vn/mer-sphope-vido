#!/bin/bash

# Content generation script

set -e

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo "Error: jq command not found. Please install jq first."
    echo "Install with: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <video-data.json> <video-duration-seconds>"
    exit 1
fi

VIDEO_DATA_FILE="$1"
VIDEO_DURATION="${2:-60}"  # Default to 60 seconds if not provided

# Check if file exists
if [ ! -f "$VIDEO_DATA_FILE" ]; then
    echo "Error: Video data file not found: $VIDEO_DATA_FILE"
    exit 1
fi

# Calculate word count based on video duration
# Average speaking rate: 150 words per minute = 2.5 words per second
# We'll use a slightly lower rate for better pacing: 2.2 words/sec = 132 words/min
WORDS_PER_SECOND=2.2
WORD_COUNT=$(echo "$VIDEO_DURATION * $WORDS_PER_SECOND" | bc | awk '{print int($1+0.5)}')

# Minimum 50 words, maximum 800 words
if [ "$WORD_COUNT" -lt 50 ]; then
    WORD_COUNT=50
fi

if [ "$WORD_COUNT" -gt 800 ]; then
    WORD_COUNT=800
fi

echo "Video duration: ${VIDEO_DURATION}s"
echo "Calculated word count: $WORD_COUNT words (at 132 words/minute)"

# Validate environment variables and select API key randomly
# Collect all available API keys
AVAILABLE_KEYS=()

if [ ! -z "$HUGGINGFACE_API_KEY" ]; then
    AVAILABLE_KEYS+=("$HUGGINGFACE_API_KEY")
fi

if [ ! -z "$HUGGINGFACE_API_KEY2" ]; then
    AVAILABLE_KEYS+=("$HUGGINGFACE_API_KEY2")
fi

if [ ! -z "$HUGGINGFACE_API_KEY3" ]; then
    AVAILABLE_KEYS+=("$HUGGINGFACE_API_KEY3")
fi

# Check if we have at least one key
if [ ${#AVAILABLE_KEYS[@]} -eq 0 ]; then
    echo "Error: No HUGGINGFACE_API_KEY found. Please set at least one of:"
    echo "  - HUGGINGFACE_API_KEY"
    echo "  - HUGGINGFACE_API_KEY2"
    echo "  - HUGGINGFACE_API_KEY3"
    exit 1
fi

if [ -z "$HUGGINGFACE_ENDPOINT" ]; then
    echo "Warning: HUGGINGFACE_ENDPOINT not set, using default"
    HUGGINGFACE_ENDPOINT="https://router.huggingface.co/v1/chat/completions"
fi

if [ -z "$HUGGINGFACE_MODEL" ]; then
    echo "Warning: HUGGINGFACE_MODEL not set, using default"
    HUGGINGFACE_MODEL="deepseek-ai/DeepSeek-V3.2-Exp"
fi

echo "Using API Endpoint: $HUGGINGFACE_ENDPOINT"
echo "Using Model: $HUGGINGFACE_MODEL"

# Extract product info with error handling
PRODUCT_NAME=$(jq -r '.productInfo.name // "Unknown Product"' "$VIDEO_DATA_FILE" 2>/dev/null)
PRICE=$(jq -r '.productInfo.price // "N/A"' "$VIDEO_DATA_FILE" 2>/dev/null)
ORIGINAL_PRICE=$(jq -r '.productInfo.originalPrice // "N/A"' "$VIDEO_DATA_FILE" 2>/dev/null)
DISCOUNT=$(jq -r '.productInfo.discount // "N/A"' "$VIDEO_DATA_FILE" 2>/dev/null)

# Check if jq parsing succeeded
if [ $? -ne 0 ]; then
    echo "Error: Failed to parse video data JSON file"
    exit 1
fi

# Convert price format: 269.000₫ -> 269k
PRICE_FORMATTED=$(echo "$PRICE" | sed 's/\.000₫/k/g' | sed 's/₫/k/g')
ORIGINAL_PRICE_FORMATTED=$(echo "$ORIGINAL_PRICE" | sed 's/\.000₫/k/g' | sed 's/₫/k/g')

echo "Product: $PRODUCT_NAME"
echo "Price: $PRICE -> $PRICE_FORMATTED"
echo "Original Price: $ORIGINAL_PRICE -> $ORIGINAL_PRICE_FORMATTED"
echo "Discount: $DISCOUNT"

# Create prompt for AI - Request JSON output
PROMPT="Hãy tạo nội dung cho video TikTok/Reels với thông tin sau:

Tên sản phẩm: $PRODUCT_NAME
Giá hiện tại: $PRICE_FORMATTED
Giá gốc: $ORIGINAL_PRICE_FORMATTED
Giảm giá: $DISCOUNT
Độ dài video: ${VIDEO_DURATION}s (cần khoảng $WORD_COUNT từ)

Yêu cầu trả về JSON với 2 trường:
1. \"script\": Đoạn giới thiệu sản phẩm đầy đủ (CHÍNH XÁC $WORD_COUNT từ, ±10% cho phép) với:
   - Giọng điệu hấp dẫn, thu hút
   - Nhấn mạnh tính năng nổi bật
   - Giá nói ngắn gọn '269k' thay vì '269.000 đồng'
   - Câu cuối PHẢI là: 'Mọi người mua sản phẩm thì ấn vào link ở giỏ hàng nha.'
   - Tiếng Việt tự nhiên, dễ nghe
   - Không dùng ký tự đặc biệt phức tạp
   - ⚠️ QUAN TRỌNG: Script phải đủ dài để khớp với video ${VIDEO_DURATION}s (~$WORD_COUNT từ)

2. \"short_title\": Tên sản phẩm rút gọn (tối đa 60 ký tự) để hiển thị trên video:
   - Giữ thông tin quan trọng nhất
   - Dễ đọc, súc tích
   - Không có dấu chấm câu thừa
   - Ví dụ: '$PRODUCT_NAME' -> rút gọn thành tên ngắn hơn

Trả về ĐÚNG định dạng JSON:
{
  \"script\": \"<nội dung giới thiệu đầy đủ>\",
  \"short_title\": \"<tên sản phẩm rút gọn>\"
}

QUAN TRỌNG: Chỉ trả về JSON, không thêm text nào khác."

# Call HuggingFace API with retry and key rotation
echo ""
echo "Calling HuggingFace API with key rotation support..."

# Track failed keys
FAILED_KEYS=()
SUCCESS=false
GENERATED_TEXT=""

# Try all available keys until one succeeds
while [ ${#AVAILABLE_KEYS[@]} -gt 0 ] && [ "$SUCCESS" = false ]; do
    # Select random key from remaining keys
    KEY_COUNT=${#AVAILABLE_KEYS[@]}
    RANDOM_INDEX=$((RANDOM % KEY_COUNT))
    CURRENT_API_KEY="${AVAILABLE_KEYS[$RANDOM_INDEX]}"
    
    # Show masked key for logging (first 10 chars)
    MASKED_KEY="${CURRENT_API_KEY:0:10}..."
    echo "Trying API key: $MASKED_KEY (${#AVAILABLE_KEYS[@]} key(s) remaining)"
    
    # Make API call
    RESPONSE=$(curl -s --max-time 60 --location "$HUGGINGFACE_ENDPOINT" \
      --header "Authorization: Bearer $CURRENT_API_KEY" \
      --header "Content-Type: application/json" \
      --data "{
        \"model\": \"$HUGGINGFACE_MODEL\",
        \"messages\": [
          {
            \"role\": \"user\",
            \"content\": $(echo "$PROMPT" | jq -Rs .)
          }
        ],
        \"max_tokens\": 1000,
        \"temperature\": 0.7
      }")
    
    # Check curl exit code
    CURL_EXIT_CODE=$?
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "Warning: curl failed with exit code $CURL_EXIT_CODE, trying next key..."
        FAILED_KEYS+=("$CURRENT_API_KEY")
        # Remove failed key from available keys
        unset AVAILABLE_KEYS[$RANDOM_INDEX]
        AVAILABLE_KEYS=("${AVAILABLE_KEYS[@]}")  # Re-index array
        continue
    fi
    
    # Check if response is empty
    if [ -z "$RESPONSE" ]; then
        echo "Warning: Empty response, trying next key..."
        FAILED_KEYS+=("$CURRENT_API_KEY")
        unset AVAILABLE_KEYS[$RANDOM_INDEX]
        AVAILABLE_KEYS=("${AVAILABLE_KEYS[@]}")
        continue
    fi
    
    # Log first 500 chars of response for debugging
    echo "API Response (first 500 chars): ${RESPONSE:0:500}"
    
    # Check for API errors in response
    API_ERROR=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null)
    if [ ! -z "$API_ERROR" ]; then
        # Check if it's a quota/rate limit error
        if echo "$API_ERROR" | grep -qi "exceeded\|quota\|rate limit\|limit reached"; then
            echo "⚠️  Quota/Rate limit error: $API_ERROR"
            echo "Switching to next available key..."
            FAILED_KEYS+=("$CURRENT_API_KEY")
            unset AVAILABLE_KEYS[$RANDOM_INDEX]
            AVAILABLE_KEYS=("${AVAILABLE_KEYS[@]}")
            continue
        else
            # Other API error - fail immediately
            echo "Error: API returned error: $API_ERROR"
            echo "Full response: $RESPONSE"
            exit 1
        fi
    fi
    
    # Extract the generated text
    GENERATED_TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    
    if [ -z "$GENERATED_TEXT" ] || [ "$GENERATED_TEXT" = "null" ]; then
        echo "Warning: No text generated, trying next key..."
        FAILED_KEYS+=("$CURRENT_API_KEY")
        unset AVAILABLE_KEYS[$RANDOM_INDEX]
        AVAILABLE_KEYS=("${AVAILABLE_KEYS[@]}")
        continue
    fi
    
    # Success!
    SUCCESS=true
    echo "✅ Successfully generated content with key: $MASKED_KEY"
done

# Fallback to Gemini if HuggingFace failed
if [ "$SUCCESS" = false ] && [ ! -z "$GEMINI_API_KEY" ]; then
    echo ""
    echo "⚠️ All HuggingFace keys failed or exhausted."
    echo "🔄 Falling back to Gemini API (gemini-1.5-flash)..."
    
    # Escape quotes in prompt for JSON
    # We need to be careful with JSON escaping for Gemini's "text" field
    # Using jq to handle escaping safely
    ESCAPED_PROMPT=$(echo "$PROMPT" | jq -Rs .)
    
    # Remove enclosing quotes from jq output as we'll put them in the json structure
    # Actually jq -Rs . outputs "string\n", so we use it directly as the value
    
    GEMINI_RESPONSE=$(curl -s --max-time 60 --location "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$GEMINI_API_KEY" \
      --header 'Content-Type: application/json' \
      --data "{
        \"contents\": [
          {
            \"parts\": [
              {
                \"text\": $ESCAPED_PROMPT
              }
            ]
          }
        ]
      }")
      
    # Check curl exit code
    if [ $? -ne 0 ]; then
        echo "Error: Gemini curl command failed"
    else
        # Check for errors
        GEMINI_ERROR=$(echo "$GEMINI_RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
        if [ ! -z "$GEMINI_ERROR" ]; then
            echo "Error: Gemini API returned error: $GEMINI_ERROR"
        else
            # Extract text
            GEMINI_TEXT=$(echo "$GEMINI_RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
            
            if [ ! -z "$GEMINI_TEXT" ] && [ "$GEMINI_TEXT" != "null" ]; then
                GENERATED_TEXT="$GEMINI_TEXT"
                SUCCESS=true
                echo "✅ Successfully generated content using Gemini API"
                
                # Clean up markdown code blocks if present (Gemini likes to wrap JSON in ```json ... ```)
                GENERATED_TEXT=$(echo "$GENERATED_TEXT" | sed 's/^```json//g' | sed 's/^```//g' | sed 's/```$//g')
            else
                echo "Error: Failed to extract text from Gemini response"
                echo "Response: ${GEMINI_RESPONSE:0:500}..."
            fi
        fi
    fi
fi

# Check if we succeeded
if [ "$SUCCESS" = false ]; then
    echo ""
    echo "❌ Error: All API keys failed or exhausted"
    echo "Failed keys: ${#FAILED_KEYS[@]}"
    echo "Please check:"
    echo "  1. API key validity"
    echo "  2. Quota remaining"
    echo "  3. Network connectivity"
    exit 1
fi

echo ""
echo "=== Generated Content ==="
echo "$GENERATED_TEXT"
echo ""

# Parse JSON response
# Try to extract script and short_title from JSON
SCRIPT_CONTENT=$(echo "$GENERATED_TEXT" | jq -r '.script // empty' 2>/dev/null)
SHORT_TITLE=$(echo "$GENERATED_TEXT" | jq -r '.short_title // empty' 2>/dev/null)

# If JSON parsing failed (AI didn't return proper JSON), treat entire response as script
if [ -z "$SCRIPT_CONTENT" ] || [ "$SCRIPT_CONTENT" = "null" ]; then
    echo "Warning: AI didn't return JSON format. Using full response as script."
    SCRIPT_CONTENT="$GENERATED_TEXT"
    
    # Create a fallback short title from original product name (first 60 chars)
    SHORT_TITLE="${PRODUCT_NAME:0:60}"
fi

# Validate we have content
if [ -z "$SCRIPT_CONTENT" ]; then
    echo "Error: No script content generated"
    exit 1
fi

if [ -z "$SHORT_TITLE" ]; then
    echo "Warning: No short title generated, using product name"
    SHORT_TITLE="${PRODUCT_NAME:0:60}"
fi

# Save to files
echo "$SCRIPT_CONTENT" > scripts/generated_script.txt
echo "$SHORT_TITLE" > scripts/short_title.txt

echo ""
echo "=== Saved Files ===="
echo "Script saved to: scripts/generated_script.txt"
echo "Short title saved to: scripts/short_title.txt"
echo ""
echo "Short title: $SHORT_TITLE"
echo ""
