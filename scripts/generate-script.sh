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

# Randomly select one key from available keys
KEY_COUNT=${#AVAILABLE_KEYS[@]}
RANDOM_INDEX=$((RANDOM % KEY_COUNT))
SELECTED_API_KEY="${AVAILABLE_KEYS[$RANDOM_INDEX]}"

echo "Found $KEY_COUNT API key(s), randomly selected key #$((RANDOM_INDEX + 1))"

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

# Call HuggingFace API
echo ""
echo "Calling HuggingFace API..."
RESPONSE=$(curl -s --max-time 60 --location "$HUGGINGFACE_ENDPOINT" \
  --header "Authorization: Bearer $SELECTED_API_KEY" \
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

# Check if request was successful
CURL_EXIT_CODE=$?
if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Error: curl command failed with exit code $CURL_EXIT_CODE"
    exit 1
fi

# Check if response is empty
if [ -z "$RESPONSE" ]; then
    echo "Error: Empty response from HuggingFace API"
    exit 1
fi

# Log first 500 chars of response for debugging
echo "API Response (first 500 chars): ${RESPONSE:0:500}"

# Check for API errors in response
API_ERROR=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null)
if [ ! -z "$API_ERROR" ]; then
    echo "Error: API returned error: $API_ERROR"
    echo "Full response: $RESPONSE"
    exit 1
fi

# Extract the generated text
GENERATED_TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [ -z "$GENERATED_TEXT" ] || [ "$GENERATED_TEXT" = "null" ]; then
    echo "Error: No text generated from API"
    echo "Full API Response: $RESPONSE"
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
