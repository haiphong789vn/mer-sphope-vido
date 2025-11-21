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
    echo "Usage: $0 <video-data.json>"
    exit 1
fi

VIDEO_DATA_FILE="$1"

# Check if file exists
if [ ! -f "$VIDEO_DATA_FILE" ]; then
    echo "Error: Video data file not found: $VIDEO_DATA_FILE"
    exit 1
fi

# Validate environment variables
if [ -z "$HUGGINGFACE_API_KEY" ]; then
    echo "Error: HUGGINGFACE_API_KEY environment variable is required"
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

# Create prompt for AI
PROMPT="Hãy viết một đoạn giới thiệu sản phẩm cho video TikTok/Reels với các thông tin sau:

Tên sản phẩm: $PRODUCT_NAME
Giá hiện tại: $PRICE_FORMATTED
Giá gốc: $ORIGINAL_PRICE_FORMATTED
Giảm giá: $DISCOUNT

Yêu cầu:
1. Tối đa 450 từ
2. Giọng điệu hấp dẫn, thu hút khách hàng
3. Nhấn mạnh các tính năng nổi bật từ tên sản phẩm
4. Không nói giá chi tiết kiểu '269.000 đồng' mà chỉ nói '269k' hoặc '429k'
5. Câu cuối cùng PHẢI là: 'Mọi người mua sản phẩm thì ấn vào link ở giỏ hàng nha.'
6. Viết bằng tiếng Việt tự nhiên, dễ nghe
7. Không dùng ký tự đặc biệt phức tạp

Hãy viết đoạn giới thiệu:"

# Call HuggingFace API
echo ""
echo "Calling HuggingFace API..."
RESPONSE=$(curl -s --max-time 60 --location "$HUGGINGFACE_ENDPOINT" \
  --header "Authorization: Bearer $HUGGINGFACE_API_KEY" \
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
echo "=== Generated Script ==="
echo "$GENERATED_TEXT"
echo ""

# Save to file
echo "$GENERATED_TEXT" > scripts/generated_script.txt

echo "Script saved to scripts/generated_script.txt"
