#!/bin/bash

# Script to generate audio from text using Edge-TTS (primary) with Zalo TTS fallback

# Don't use set -e because we want to handle errors and try fallback
set +e

if [ -z "$1" ]; then
    echo "Usage: $0 <text-file>"
    exit 1
fi

TEXT_FILE="$1"

if [ ! -f "$TEXT_FILE" ]; then
    echo "Error: Text file not found: $TEXT_FILE"
    exit 1
fi

# Read the text content
TEXT_CONTENT=$(cat "$TEXT_FILE")

echo "Generating audio for text (${#TEXT_CONTENT} characters)..."

# Function to use Edge-TTS (Primary)
use_edge_tts() {
    echo ""
    echo "=========================================="
    echo "🎤 Using Edge-TTS (Microsoft) - Primary"
    echo "=========================================="

    # Check if edge-tts is installed, if not install it
    if ! command -v edge-tts &> /dev/null; then
        echo "Installing Edge-TTS..."
        pip install -q edge-tts
    fi

    # Save text to temp file to avoid command-line escaping issues
    TEMP_TEXT_FILE="output/temp_text_for_tts.txt"
    echo "$TEXT_CONTENT" > "$TEMP_TEXT_FILE"

    # Use Vietnamese voice from Edge-TTS
    # vi-VN-HoaiMyNeural is a female Vietnamese voice
    # vi-VN-NamMinhNeural is a male Vietnamese voice
    echo "Generating audio with Edge-TTS (Vietnamese voice: vi-VN-HoaiMyNeural)..."
    echo "Text length: ${#TEXT_CONTENT} characters"

    # Use file input to avoid command-line issues with special characters
    edge-tts --voice "vi-VN-HoaiMyNeural" --file "$TEMP_TEXT_FILE" --write-media output/voiceover.mp3 2>&1

    EXIT_CODE=$?

    # Clean up temp file
    rm -f "$TEMP_TEXT_FILE"

    if [ $EXIT_CODE -eq 0 ] && [ -f "output/voiceover.mp3" ]; then
        # Check if mp3 file has content
        FILE_SIZE=$(stat -f%z "output/voiceover.mp3" 2>/dev/null || stat -c%s "output/voiceover.mp3" 2>/dev/null || echo "0")

        if [ "$FILE_SIZE" -lt 1000 ]; then
            echo "❌ Edge-TTS generated empty or invalid audio file"
            rm -f output/voiceover.mp3
            return 1
        fi

        # Convert mp3 to wav for consistency
        echo "Converting mp3 to wav..."
        ffmpeg -i output/voiceover.mp3 -y output/voiceover.wav 2>&1 | tail -5

        if [ -f "output/voiceover.wav" ]; then
            # Check if wav file has content
            WAV_SIZE=$(stat -f%z "output/voiceover.wav" 2>/dev/null || stat -c%s "output/voiceover.wav" 2>/dev/null || echo "0")
            if [ "$WAV_SIZE" -gt 1000 ]; then
                rm -f output/voiceover.mp3
                echo "✅ Edge-TTS audio generated successfully: output/voiceover.wav"
                ls -lh output/voiceover.wav
                return 0
            else
                echo "❌ Edge-TTS generated empty wav file"
                rm -f output/voiceover.mp3 output/voiceover.wav
                return 1
            fi
        else
            echo "❌ Failed to convert Edge-TTS audio to wav"
            rm -f output/voiceover.mp3
            return 1
        fi
    else
        echo "❌ Edge-TTS failed (exit code: $EXIT_CODE)"
        return 1
    fi
}

# Function to use Google Translate TTS (gTTS) as fallback
use_gtts_fallback() {
    echo ""
    echo "=========================================="
    echo "🔄 Using Google Translate TTS (gTTS) fallback"
    echo "=========================================="

    # Check if gTTS is installed
    if ! command -v gtts-cli &> /dev/null; then
        echo "Installing gTTS..."
        pip install -q gTTS
    fi

    echo "Generating audio with gTTS (Vietnamese)..."
    
    # Save text to temp file
    TEMP_TEXT_FILE="output/temp_text_for_tts.txt"
    echo "$TEXT_CONTENT" > "$TEMP_TEXT_FILE"

    # Generate audio using gTTS CLI
    # -l vi: Vietnamese language
    gtts-cli -f "$TEMP_TEXT_FILE" -l vi --output output/voiceover.mp3 2>&1

    EXIT_CODE=$?
    rm -f "$TEMP_TEXT_FILE"

    if [ $EXIT_CODE -eq 0 ] && [ -f "output/voiceover.mp3" ]; then
        echo "Converting mp3 to wav..."
        ffmpeg -i output/voiceover.mp3 -y output/voiceover.wav 2>&1 | tail -5
        
        if [ -f "output/voiceover.wav" ]; then
            rm -f output/voiceover.mp3
            echo "✅ gTTS audio generated successfully: output/voiceover.wav"
            ls -lh output/voiceover.wav
            return 0
        else
            echo "❌ Failed to convert gTTS audio to wav"
            return 1
        fi
    else
        echo "❌ gTTS failed (exit code: $EXIT_CODE)"
        return 1
    fi
}

# Function to use Zalo TTS as last resort
use_zalo_tts_fallback() {
    echo ""
    echo "=========================================="
    echo "🔄 Using Zalo TTS fallback"
    echo "=========================================="

    if [ -z "$ZALO_API_KEY" ]; then
        echo "⚠️ ZALO_API_KEY not set, skipping Zalo TTS fallback"
        return 1
    fi

    echo "Trying Zalo TTS API..."
    RESPONSE=$(curl -s --location 'https://api.zalo.ai/v1/tts/synthesize' \
      --header "apikey: $ZALO_API_KEY" \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'speaker_id=1' \
      --data-urlencode 'speed=1' \
      --data-urlencode "input=$TEXT_CONTENT")

    # Check if request was successful
    if [ $? -ne 0 ]; then
        echo "⚠️ Zalo TTS API request failed"
        return 1
    fi

    echo "Zalo API Response: $RESPONSE"

    # Extract error code
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error_code')

    if [ "$ERROR_CODE" != "0" ]; then
        ERROR_MESSAGE=$(echo "$RESPONSE" | jq -r '.error_message')
        echo "⚠️ Zalo API Error: $ERROR_MESSAGE (code: $ERROR_CODE)"
        return 1
    fi

    # Extract audio URL
    AUDIO_URL=$(echo "$RESPONSE" | jq -r '.data.url')

    if [ -z "$AUDIO_URL" ] || [ "$AUDIO_URL" = "null" ]; then
        echo "⚠️ No audio URL in Zalo response"
        return 1
    fi

    echo "✅ Zalo Audio URL: $AUDIO_URL"

    # Download the audio file
    echo "Downloading audio file from Zalo..."
    curl -L -o output/voiceover.wav "$AUDIO_URL"

    if [ $? -eq 0 ] && [ -f "output/voiceover.wav" ]; then
        echo "✅ Zalo TTS audio downloaded successfully: output/voiceover.wav"
        ls -lh output/voiceover.wav
        return 0
    else
        echo "⚠️ Failed to download from Zalo"
        return 1
    fi
}

# Function to use ElevenLabs TTS (Primary)
use_elevenlabs_tts() {
    echo ""
    echo "=========================================="
    echo "🗣️ Using ElevenLabs TTS - Primary"
    echo "=========================================="

    if [ -z "$ELEVENLABS_API_KEY" ]; then
        echo "⚠️ ELEVENLABS_API_KEY not set, skipping ElevenLabs TTS"
        return 1
    fi

    # Voice IDs requested by user
    # Bradford: NNl6r8mD7vthiJatiJt1
    # Juniper: aMSt68OGf4xUZAnLpTU8
    
    # Randomly select one of the two voices
    if [ $((RANDOM % 2)) -eq 0 ]; then
        VOICE_ID="NNl6r8mD7vthiJatiJt1" # Bradford
        VOICE_NAME="Bradford"
    else
        VOICE_ID="aMSt68OGf4xUZAnLpTU8" # Juniper
        VOICE_NAME="Juniper"
    fi

    # Use the latest V3 model as requested
    MODEL_ID="eleven_v3"

    echo "Generating audio with ElevenLabs (Voice: $VOICE_NAME, Model: $MODEL_ID)..."
    
    # API Endpoint
    URL="https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID"

    # Create JSON payload using jq to safely handle special characters and newlines
    JSON_PAYLOAD=$(jq -n \
                  --arg text "$TEXT_CONTENT" \
                  --arg model "$MODEL_ID" \
                  '{
                    text: $text,
                    model_id: $model,
                    voice_settings: {
                      stability: 0.5,
                      similarity_boost: 0.75
                    }
                  }')

    # Make API request
    # Note: Using --fail to catch 401/400 errors
    RESPONSE_CODE=$(curl -s -o output/voiceover.mp3 -w "%{http_code}" \
        --request POST \
        --url "$URL" \
        --header "xi-api-key: $ELEVENLABS_API_KEY" \
        --header "Content-Type: application/json" \
        --data "$JSON_PAYLOAD")

    if [ "$RESPONSE_CODE" -eq 200 ] && [ -f "output/voiceover.mp3" ]; then
        # Check file size
        FILE_SIZE=$(stat -f%z "output/voiceover.mp3" 2>/dev/null || stat -c%s "output/voiceover.mp3" 2>/dev/null || echo "0")
        
        if [ "$FILE_SIZE" -lt 1000 ]; then
            echo "❌ ElevenLabs generated empty/small file ($FILE_SIZE bytes)"
            return 1
        fi

        echo "Converting mp3 to wav..."
        ffmpeg -i output/voiceover.mp3 -y output/voiceover.wav 2>&1 | tail -5
        
        if [ -f "output/voiceover.wav" ]; then
            rm -f output/voiceover.mp3
            echo "✅ ElevenLabs audio generated successfully: output/voiceover.wav"
            return 0
        else
            echo "❌ Failed to convert ElevenLabs audio to wav"
            return 1
        fi
    else
        echo "❌ ElevenLabs API failed with status code: $RESPONSE_CODE"
        # If response body exists, print it for debugging (it might be in output/voiceover.mp3 if curl saved it)
        if [ -f "output/voiceover.mp3" ]; then
            cat output/voiceover.mp3
            rm output/voiceover.mp3
        fi
        return 1
    fi
}

# Try ElevenLabs first (Primary)
if use_elevenlabs_tts; then
    echo ""
    echo "✅ Audio generation completed with ElevenLabs (Primary)"
    exit 0
fi

# If ElevenLabs fails, try Edge-TTS (Secondary)
echo ""
echo "⚠️ ElevenLabs failed, trying Edge-TTS fallback..."
if use_edge_tts; then
    echo ""
    echo "✅ Audio generation completed with Edge-TTS (Secondary)"
    exit 0
fi

# If Edge-TTS fails, try gTTS (Tertiary)
echo ""
echo "⚠️ Edge-TTS failed, trying gTTS fallback..."
if use_gtts_fallback; then
    echo ""
    echo "✅ Audio generation completed with gTTS (Tertiary)"
    exit 0
fi

# If gTTS fails, try Zalo TTS as last resort
echo ""
echo "⚠️ gTTS failed, trying Zalo TTS fallback..."
if use_zalo_tts_fallback; then
    echo ""
    echo "✅ Audio generation completed with Zalo TTS (Last Resort)"
    exit 0
fi

# All failed
echo ""
echo "❌ Failed to generate audio with any TTS service"
exit 1
