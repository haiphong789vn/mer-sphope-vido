#!/usr/bin/env python3
"""
Video Processing Script
Database-driven video processing with cloud storage integration
"""

import os
import sys
import json
import subprocess
import psycopg2
from psycopg2.extras import RealDictCursor
import boto3
from botocore.client import Config
from datetime import datetime
import logging
from pathlib import Path
from typing import Dict, List, Optional
import tempfile
import shutil

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class VideoProcessor:
    """Main video processing class"""

    def __init__(self):
        """Initialize with environment variables"""
        # Database config
        self.db_url = os.getenv('DATABASE_URL')
        if not self.db_url:
            raise ValueError("DATABASE_URL environment variable is required")

        # R2 config
        self.r2_access_key = os.getenv('R2_ACCESS_KEY_ID')
        self.r2_secret_key = os.getenv('R2_SECRET_ACCESS_KEY')
        self.r2_endpoint = os.getenv('R2_ENDPOINT')
        self.r2_bucket = os.getenv('R2_BUCKET_NAME', 'yt-2-tiktok')

        if not all([self.r2_access_key, self.r2_secret_key, self.r2_endpoint]):
            raise ValueError("R2 credentials (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT) are required")

        # AI/TTS config
        self.huggingface_endpoint = os.getenv('HUGGINGFACE_ENDPOINT', 'https://router.huggingface.co/v1/chat/completions')
        self.huggingface_model = os.getenv('HUGGINGFACE_MODEL', 'deepseek-ai/DeepSeek-V3.2-Exp')
        self.huggingface_api_key = os.getenv('HUGGINGFACE_API_KEY')
        self.zalo_api_key = os.getenv('ZALO_API_KEY')

        # Working directories
        self.base_dir = Path(__file__).parent
        self.videos_dir = self.base_dir / 'videos'
        self.output_dir = self.base_dir / 'output'
        self.scripts_dir = self.base_dir / 'scripts'

        # Initialize R2 client
        self.r2_client = boto3.client(
            's3',
            endpoint_url=self.r2_endpoint,
            aws_access_key_id=self.r2_access_key,
            aws_secret_access_key=self.r2_secret_key,
            config=Config(signature_version='s3v4')
        )

    def setup_directories(self):
        """Create necessary working directories"""
        for directory in [self.videos_dir, self.output_dir, self.scripts_dir]:
            directory.mkdir(exist_ok=True)
            logger.info(f"Directory ready: {directory}")

    def cleanup_directories(self):
        """Clean up working directories"""
        for directory in [self.videos_dir, self.output_dir]:
            if directory.exists():
                shutil.rmtree(directory)
                directory.mkdir(exist_ok=True)
        logger.info("Cleaned up working directories")

    def get_pending_products(self) -> List[Dict]:
        """Fetch products from database where merge_status=FALSE"""
        try:
            conn = psycopg2.connect(self.db_url)
            cursor = conn.cursor(cursor_factory=RealDictCursor)

            query = """
                SELECT id, video_data
                FROM public.products
                WHERE merge_status = FALSE
                AND video_data IS NOT NULL
                AND video_data::text != 'null'
                ORDER BY id
            """

            cursor.execute(query)
            products = cursor.fetchall()

            cursor.close()
            conn.close()

            logger.info(f"Found {len(products)} pending products")
            return products

        except Exception as e:
            logger.error(f"Database error: {e}")
            raise

    def update_merge_status(self, product_id: int, r2_url: str):
        """Update merge_status to TRUE after successful processing"""
        try:
            conn = psycopg2.connect(self.db_url)
            cursor = conn.cursor()

            query = """
                UPDATE public.products
                SET merge_status = TRUE,
                    r2_video_url = %s,
                    processed_at = NOW()
                WHERE id = %s
            """

            cursor.execute(query, (r2_url, product_id))
            conn.commit()

            cursor.close()
            conn.close()

            logger.info(f"Updated product {product_id} merge_status to TRUE")

        except Exception as e:
            logger.error(f"Failed to update database: {e}")
            raise

    def process_product(self, product_id: int, video_data: Dict) -> Optional[str]:
        """
        Process a single product: download videos, merge, add audio/text, upload to R2
        Returns R2 URL if successful, None otherwise
        """
        try:
            # Validate video_data is not None
            if video_data is None:
                logger.error(f"Product {product_id}: video_data is NULL - skipping")
                return None

            # Validate video_data has required structure
            if not isinstance(video_data, dict):
                logger.error(f"Product {product_id}: video_data is not a dict - skipping")
                return None

            # Validate has videos array
            videos = video_data.get('videos', [])
            if not videos or not isinstance(videos, list) or len(videos) == 0:
                logger.error(f"Product {product_id}: no videos found in video_data - skipping")
                return None

            product_name = video_data.get('productInfo', {}).get('name', 'Unknown')
            logger.info(f"Processing product {product_id}: {product_name}")

            # Save video data to JSON file for existing scripts to use
            video_data_file = self.base_dir / 'video-data.json'
            with open(video_data_file, 'w', encoding='utf-8') as f:
                json.dump(video_data, f, ensure_ascii=False, indent=2)

            # Download videos
            if not self.download_videos(video_data):
                return None

            # Process videos (trim)
            if not self.process_videos(video_data):
                return None

            # Merge videos
            if not self.merge_videos(video_data):
                return None

            # Get merged video duration for script generation
            merged_video = self.output_dir / 'merged_temp.mp4'
            try:
                result = subprocess.run([
                    'ffprobe', '-v', 'error',
                    '-show_entries', 'format=duration',
                    '-of', 'default=noprint_wrappers=1:nokey=1',
                    str(merged_video)
                ], capture_output=True, text=True, check=True)
                
                video_duration = float(result.stdout.strip())
                logger.info(f"Merged video duration: {video_duration:.2f} seconds")
            except Exception as e:
                logger.warning(f"Could not get video duration: {e}. Using default.")
                video_duration = 60.0  # Default fallback

            # Generate AI script with video duration
            if not self.generate_script(video_data_file, video_duration):
                return None

            # Generate audio
            if not self.generate_audio():
                return None

            # Add audio to video
            if not self.add_audio():
                return None

            # Add text overlay
            # Try to read short title from file (generated by AI)
            short_title_file = self.scripts_dir / 'short_title.txt'
            if short_title_file.exists():
                with open(short_title_file, 'r', encoding='utf-8') as f:
                    product_name = f.read().strip()
                logger.info(f"Using AI-generated short title: {product_name}")
            else:
                # Fallback to full product name
                product_name = video_data.get('productInfo', {}).get('name', 'Product')
                logger.warning(f"short_title.txt not found, using full product name")
            
            if not self.add_text_overlay(product_name):
                return None

            # Upscale to 1080p
            if not self.upscale_to_1080p():
                return None

            # Upload to R2
            final_video = self.output_dir / 'final_merged_video_1080p.mp4'
            r2_url = self.upload_to_r2(final_video, product_id, video_data)

            return r2_url

        except Exception as e:
            logger.error(f"Error processing product {product_id}: {e}")
            return None

    def download_videos(self, video_data: Dict) -> bool:
        """Download all videos from URLs"""
        try:
            videos = video_data.get('videos', [])
            logger.info(f"Downloading {len(videos)} videos...")

            for i, video in enumerate(videos):
                url = video.get('url')
                if not url:
                    logger.error(f"Video {i+1}: No URL provided")
                    return False
                    
                output_path = self.videos_dir / f'video_{i}.mp4'

                # Download with retry
                max_retries = 3
                download_success = False
                
                for retry in range(max_retries):
                    try:
                        # Download the file
                        result = subprocess.run([
                            'curl', '-L', '-o', str(output_path), url,
                            '--max-time', '300',
                            '--connect-timeout', '30',
                            '--fail'  # Fail on HTTP errors
                        ], check=True, capture_output=True, text=True)

                        # Validate downloaded file
                        if not output_path.exists():
                            raise Exception("File not created after download")
                        
                        file_size = output_path.stat().st_size
                        if file_size == 0:
                            raise Exception(f"Downloaded file is empty (0 bytes)")
                        
                        if file_size < 1024:  # Less than 1KB is suspicious
                            logger.warning(f"Video {i+1}: Small file size ({file_size} bytes)")
                        
                        # Verify file is a valid video with ffprobe
                        verify_result = subprocess.run([
                            'ffprobe', '-v', 'error',
                            '-show_entries', 'format=duration',
                            '-of', 'default=noprint_wrappers=1:nokey=1',
                            str(output_path)
                        ], capture_output=True, text=True)
                        
                        if verify_result.returncode != 0:
                            raise Exception(f"Invalid video file. ffprobe error: {verify_result.stderr}")
                        
                        logger.info(f"Downloaded video {i+1}/{len(videos)} ({file_size:,} bytes)")
                        download_success = True
                        break
                        
                    except subprocess.CalledProcessError as e:
                        error_msg = e.stderr if hasattr(e, 'stderr') and e.stderr else str(e)
                        logger.warning(f"Download attempt {retry+1} failed: {error_msg}")
                        
                        # Clean up potentially corrupted file
                        if output_path.exists():
                            output_path.unlink()
                        
                        if retry < max_retries - 1:
                            logger.warning(f"Retrying download... ({retry+1}/{max_retries})")
                            continue
                        else:
                            logger.error(f"Failed to download video {i+1} after {max_retries} attempts")
                            return False
                            
                    except Exception as e:
                        logger.warning(f"Download attempt {retry+1} failed: {e}")
                        
                        # Clean up potentially corrupted file
                        if output_path.exists():
                            output_path.unlink()
                        
                        if retry < max_retries - 1:
                            logger.warning(f"Retrying download... ({retry+1}/{max_retries})")
                            continue
                        else:
                            logger.error(f"Failed to download video {i+1} after {max_retries} attempts: {e}")
                            return False
                
                if not download_success:
                    logger.error(f"Failed to download valid video {i+1}")
                    return False

            return True

        except Exception as e:
            logger.error(f"Error downloading videos: {e}")
            return False

    def process_videos(self, video_data: Dict) -> bool:
        """Trim 2 seconds from start and end of each video"""
        try:
            videos = video_data.get('videos', [])
            logger.info("Processing videos (trimming)...")

            for i in range(len(videos)):
                input_path = self.videos_dir / f'video_{i}.mp4'
                output_path = self.videos_dir / f'trimmed_{i}.mp4'
                
                # Verify input file exists and has size
                if not input_path.exists():
                    logger.error(f"Video {i+1}: Input file not found: {input_path}")
                    return False
                
                file_size = input_path.stat().st_size
                if file_size == 0:
                    logger.error(f"Video {i+1}: Input file is empty (0 bytes)")
                    return False

                try:
                    # Get duration
                    result = subprocess.run([
                        'ffprobe', '-v', 'error',
                        '-show_entries', 'format=duration',
                        '-of', 'default=noprint_wrappers=1:nokey=1',
                        str(input_path)
                    ], capture_output=True, text=True, check=True)

                    duration = float(result.stdout.strip())
                    new_duration = duration - 4

                    if new_duration > 0:
                        # Trim video
                        subprocess.run([
                            'ffmpeg', '-i', str(input_path),
                            '-ss', '2', '-t', str(new_duration),
                            '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                            '-c:a', 'aac', '-b:a', '128k', '-ar', '48000',
                            '-r', '30',
                            '-y', str(output_path)
                        ], check=True, capture_output=True)

                        logger.info(f"Trimmed video {i+1}: {duration:.2f}s -> {new_duration:.2f}s")
                    else:
                        # Video too short, keep original
                        shutil.copy(input_path, output_path)
                        logger.warning(f"Video {i+1} too short ({duration:.2f}s), keeping original")
                        
                except subprocess.CalledProcessError as e:
                    error_output = e.stderr if hasattr(e, 'stderr') and e.stderr else 'No error output'
                    logger.error(f"Video {i+1}: Failed to process - {error_output}")
                    logger.error(f"Video {i+1}: File size: {file_size:,} bytes, Path: {input_path}")
                    return False
                except ValueError as e:
                    logger.error(f"Video {i+1}: Invalid duration value - {e}")
                    return False

            return True

        except Exception as e:
            logger.error(f"Error processing videos: {e}")
            import traceback
            logger.error(f"Traceback: {traceback.format_exc()}")
            return False

    def merge_videos(self, video_data: Dict) -> bool:
        """Merge all trimmed videos into one"""
        try:
            logger.info("Merging videos...")

            # Create concat list
            concat_file = self.videos_dir / 'concat_list.txt'
            videos = video_data.get('videos', [])

            with open(concat_file, 'w') as f:
                for i in range(len(videos)):
                    f.write(f"file 'trimmed_{i}.mp4'\n")

            # Merge with ffmpeg
            output_path = self.output_dir / 'merged_temp.mp4'

            subprocess.run([
                'ffmpeg', '-f', 'concat', '-safe', '0',
                '-i', str(concat_file),
                '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                '-c:a', 'aac', '-b:a', '128k', '-ar', '48000',
                '-r', '30',
                '-movflags', '+faststart',
                '-y', str(output_path)
            ], check=True, capture_output=True)

            logger.info("Videos merged successfully")
            return True

        except Exception as e:
            logger.error(f"Error merging videos: {e}")
            return False

    def generate_script(self, video_data_file: Path, video_duration: float) -> bool:
        """Generate AI script using existing bash script"""
        try:
            logger.info(f"Generating AI script for {video_duration:.2f}s video...")

            env = os.environ.copy()
            env['HUGGINGFACE_ENDPOINT'] = self.huggingface_endpoint
            env['HUGGINGFACE_MODEL'] = self.huggingface_model
            env['HUGGINGFACE_API_KEY'] = self.huggingface_api_key
            # Pass Gemini key for fallback
            env['GEMINI_API_KEY'] = os.environ.get('GEMINI_API_KEY', '')

            script_path = self.scripts_dir / 'generate-script.sh'

            # Pass video duration as second argument
            result = subprocess.run([
                'bash', str(script_path), str(video_data_file), str(video_duration)
            ], check=True, env=env, capture_output=True, text=True)

            logger.info("AI script generated successfully")
            return True

        except subprocess.CalledProcessError as e:
            logger.error(f"Error generating script: {e}")
            logger.error(f"Script stdout: {e.stdout}")
            logger.error(f"Script stderr: {e.stderr}")
            return False
        except Exception as e:
            logger.error(f"Error generating script: {e}")
            return False

    def generate_audio(self) -> bool:
        """Generate audio using existing bash script"""
        try:
            logger.info("Generating audio...")

            env = os.environ.copy()
            if self.zalo_api_key:
                env['ZALO_API_KEY'] = self.zalo_api_key

            script_path = self.scripts_dir / 'generate-audio.sh'
            text_file = self.scripts_dir / 'generated_script.txt'

            subprocess.run([
                'bash', str(script_path), str(text_file)
            ], check=True, env=env)

            audio_file = self.output_dir / 'voiceover.wav'
            if not audio_file.exists():
                logger.error("Audio file not generated")
                return False

            logger.info("Audio generated successfully")
            return True

        except Exception as e:
            logger.error(f"Error generating audio: {e}")
            return False

    def add_audio(self) -> bool:
        """Add audio to merged video"""
        try:
            logger.info("Adding audio to video...")

            # Normalize audio
            subprocess.run([
                'ffmpeg', '-i', str(self.output_dir / 'voiceover.wav'),
                '-ar', '48000', '-ac', '2', '-c:a', 'aac', '-b:a', '192k',
                '-y', str(self.output_dir / 'voiceover_normalized.aac')
            ], check=True, capture_output=True)

            # Add audio to video
            subprocess.run([
                'ffmpeg',
                '-i', str(self.output_dir / 'merged_temp.mp4'),
                '-i', str(self.output_dir / 'voiceover_normalized.aac'),
                '-map', '0:v', '-map', '1:a',
                '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                '-c:a', 'copy',
                '-shortest',
                '-y', str(self.output_dir / 'merged_with_audio.mp4')
            ], check=True, capture_output=True)

            logger.info("Audio added to video successfully")
            return True

        except Exception as e:
            logger.error(f"Error adding audio: {e}")
            return False

    def add_text_overlay(self, product_name: str) -> bool:
        """Add text overlay to video"""
        try:
            logger.info("Adding text overlay...")

            # Get video dimensions
            result = subprocess.run([
                'ffprobe', '-v', 'error',
                '-select_streams', 'v:0',
                '-show_entries', 'stream=width,height',
                '-of', 'csv=s=x:p=0',
                str(self.output_dir / 'merged_with_audio.mp4')
            ], capture_output=True, text=True, check=True)

            dimensions = result.stdout.strip()
            width, height = map(int, dimensions.split('x'))
            logger.info(f"Video dimensions: {width}x{height}")

            # Smart text wrapping based on length
            # Vietnamese text typically needs more wrapping due to diacritics
            name_length = len(product_name)
            
            # Determine number of lines needed
            # Each line should have max ~40 characters for readability
            max_chars_per_line = 40
            num_lines = max(1, (name_length + max_chars_per_line - 1) // max_chars_per_line)
            
            # Cap at 4 lines maximum
            num_lines = min(num_lines, 4)
            
            # Wrap text if needed
            if num_lines > 1:
                display_text = self._wrap_text(product_name, num_lines)
            else:
                display_text = product_name
            
            # Determine font size based on number of lines and video width
            # Smaller font for more lines, larger for fewer lines
            if width >= 1080:
                # HD video
                base_size = 48
            else:
                # SD video
                base_size = 36
            
            # Adjust based on number of lines
            if num_lines == 1:
                fontsize = base_size
            elif num_lines == 2:
                fontsize = int(base_size * 0.75)
            elif num_lines == 3:
                fontsize = int(base_size * 0.6)
            else:  # 4+ lines
                fontsize = int(base_size * 0.5)
            
            logger.info(f"Text wrapping: {num_lines} lines, font size: {fontsize}")

            # Escape text for ffmpeg
            # Important: escape special characters for drawtext filter
            escaped_text = display_text.replace("'", "'\\\\''")
            escaped_text = escaped_text.replace(":", "\\:")
            escaped_text = escaped_text.replace("%", "\\%")
            
            # Calculate vertical position based on number of lines
            # More lines need to start higher to fit
            y_pos = 40 if num_lines > 2 else 60

            # Add text overlay with better formatting
            subprocess.run([
                'ffmpeg',
                '-i', str(self.output_dir / 'merged_with_audio.mp4'),
                '-vf', f"drawtext=text='{escaped_text}':fontsize={fontsize}:fontcolor=white:x=(w-text_w)/2:y={y_pos}:box=1:boxcolor=black@0.85:boxborderw=20:line_spacing=8",
                '-c:a', 'copy',
                '-y', str(self.output_dir / 'final_merged_video.mp4')
            ], check=True, capture_output=True)

            logger.info("Text overlay added successfully")
            return True

        except Exception as e:
            logger.error(f"Error adding text overlay: {e}")
            return False

    def _wrap_text(self, text: str, lines: int) -> str:
        """Wrap text into multiple lines"""
        length = len(text)
        chunk_size = length // lines

        result_lines = []
        current_pos = 0

        for i in range(lines - 1):
            # Find best split point near chunk boundary
            target = current_pos + chunk_size
            best_split = target

            # Search for space/comma/dash near target
            for offset in range(20):
                for pos in [target + offset, target - offset]:
                    if pos < length and pos > current_pos:
                        if text[pos] in ' ,-':
                            best_split = pos
                            break
                if best_split != target:
                    break

            result_lines.append(text[current_pos:best_split].strip())
            current_pos = best_split

        # Add remaining text as last line
        result_lines.append(text[current_pos:].strip())

        return '\\n'.join(result_lines)

    def upscale_to_1080p(self) -> bool:
        """Upscale video to 1080p resolution (1920x1080)"""
        try:
            logger.info("Upscaling video to 1080p...")

            input_video = self.output_dir / 'final_merged_video.mp4'
            output_video = self.output_dir / 'final_merged_video_1080p.mp4'

            # Get current video dimensions
            result = subprocess.run([
                'ffprobe', '-v', 'error',
                '-select_streams', 'v:0',
                '-show_entries', 'stream=width,height',
                '-of', 'csv=s=x:p=0',
                str(input_video)
            ], capture_output=True, text=True, check=True)

            current_dimensions = result.stdout.strip()
            logger.info(f"Current dimensions: {current_dimensions}")

            # Upscale to 1080p (Vertical/Shorts) with high quality settings
            # Using lanczos for best quality upscaling
            # Maintain aspect ratio with padding if needed
            subprocess.run([
                'ffmpeg',
                '-i', str(input_video),
                '-vf', 'scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black',
                '-c:v', 'libx264',
                '-preset', 'slow',
                '-crf', '18',
                '-c:a', 'copy',
                '-movflags', '+faststart',
                '-y', str(output_video)
            ], check=True, capture_output=True)

            logger.info(f"Video upscaled to 1080p: {current_dimensions} -> 1920x1080")
            return True

        except Exception as e:
            logger.error(f"Error upscaling video: {e}")
            return False

    def upload_to_r2(self, video_path: Path, product_id: int, video_data: Dict) -> Optional[str]:
        """Upload video to Cloudflare R2"""
        try:
            logger.info("Uploading to Cloudflare R2...")

            # Generate R2 key
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            product_name_slug = video_data.get('productInfo', {}).get('name', 'product')
            # Clean filename
            product_name_slug = ''.join(c if c.isalnum() or c in '-_' else '_' for c in product_name_slug)[:50]

            r2_key = f"merged_videos/{timestamp}_product_{product_id}_{product_name_slug}.mp4"

            # Upload to R2
            with open(video_path, 'rb') as f:
                self.r2_client.put_object(
                    Bucket=self.r2_bucket,
                    Key=r2_key,
                    Body=f,
                    ContentType='video/mp4',
                    Metadata={
                        'product_id': str(product_id),
                        'processed_at': datetime.now().isoformat()
                    }
                )

            # Generate public URL
            r2_public_url = f"https://pub-09ecd227972848afb3d86c1f7f2b57b1.r2.dev/{r2_key}"

            logger.info(f"Video uploaded to R2: {r2_public_url}")
            return r2_public_url

        except Exception as e:
            logger.error(f"Error uploading to R2: {e}")
            return None

    def run(self):
        """Main processing loop"""
        logger.info("Starting video processing...")

        # Setup directories
        self.setup_directories()

        # Get pending products
        products = self.get_pending_products()

        if not products:
            logger.info("No pending products to process")
            return

        # Process each product
        success_count = 0
        failed_count = 0
        skipped_count = 0

        for product in products:
            product_id = product['id']
            video_data = product['video_data']

            # Validate product data before processing
            if video_data is None:
                logger.warning(f"⚠️  Product {product_id}: video_data is NULL - skipping")
                skipped_count += 1
                continue

            if not isinstance(video_data, dict):
                logger.warning(f"⚠️  Product {product_id}: video_data is not valid JSON - skipping")
                skipped_count += 1
                continue

            videos = video_data.get('videos', [])
            if not videos or not isinstance(videos, list) or len(videos) == 0:
                logger.warning(f"⚠️  Product {product_id}: no videos in video_data - skipping")
                skipped_count += 1
                continue

            # Clean up before processing each product
            self.cleanup_directories()

            # Process product
            r2_url = self.process_product(product_id, video_data)

            if r2_url:
                # Update database
                try:
                    self.update_merge_status(product_id, r2_url)
                    success_count += 1
                    logger.info(f"✅ Product {product_id} processed successfully")
                except Exception as e:
                    logger.error(f"Failed to update database for product {product_id}: {e}")
                    failed_count += 1
            else:
                failed_count += 1
                logger.error(f"❌ Failed to process product {product_id}")

        # Summary
        logger.info("=" * 50)
        logger.info(f"Processing complete!")
        logger.info(f"Success: {success_count}")
        logger.info(f"Failed: {failed_count}")
        logger.info(f"Skipped (invalid data): {skipped_count}")
        logger.info(f"Total: {len(products)}")
        logger.info("=" * 50)


def main():
    """Entry point"""
    try:
        processor = VideoProcessor()
        processor.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
