# GitHub Actions Workflows

Repository này có 3 workflows chính:

## 1. 🔄 Run Database Migration

**File:** `run-migration.yml`

**Mục đích:** Chạy database migration để thêm các cột cần thiết vào bảng `products`.

**Khi nào chạy:**
- Chạy **một lần** sau khi clone/setup repository lần đầu
- Chạy khi cần thêm các cột mới vào database
- An toàn để chạy nhiều lần (idempotent)

**Cách chạy:**

1. Vào tab **Actions** trong repository
2. Chọn workflow **Run Database Migration**
3. Click **Run workflow**
4. **Quan trọng:** Nhập `migrate` vào ô xác nhận
5. Click **Run workflow** để chạy

**Yêu cầu:**
- GitHub Secret `DATABASE_URL` phải được cấu hình

**Kết quả:**
- ✅ Thêm cột `r2_video_url` (TEXT) vào bảng products
- ✅ Thêm cột `processed_at` (TIMESTAMP) vào bảng products
- ✅ Tạo index cho `processed_at`
- ✅ Verify migration thành công

---

## 2. 🎬 Process Videos from Database to R2

**File:** `process-from-database.yml`

**Mục đích:** Tự động xử lý video từ database và upload lên Cloudflare R2.

**Khi nào chạy:**
- ✅ **Tự động:** Mỗi giờ (cron schedule)
- ✅ **Thủ công:** Có thể trigger bất kỳ lúc nào

**Quy trình:**

1. Lấy tất cả products có `merge_status=FALSE` từ database
2. Với mỗi product:
   - Download các video từ URLs
   - Trim 2 giây đầu/cuối
   - Merge thành 1 video
   - Tạo AI script (DeepSeek)
   - Generate voiceover (Edge-TTS hoặc Zalo TTS)
   - Thêm audio + text overlay
   - Upload lên Cloudflare R2
3. Cập nhật database:
   - `merge_status` → `TRUE`
   - `r2_video_url` → URL công khai
   - `processed_at` → Timestamp hiện tại

**Yêu cầu:**

GitHub Secrets cần thiết:
- `DATABASE_URL` - PostgreSQL connection string
- `R2_ACCESS_KEY_ID` - Cloudflare R2 access key
- `R2_SECRET_ACCESS_KEY` - Cloudflare R2 secret key
- `R2_ENDPOINT` - Cloudflare R2 endpoint URL
- `R2_BUCKET_NAME` - Tên R2 bucket
- `HUGGINGFACE_API_KEY` - HuggingFace API key

Secrets tùy chọn:
- `ZALO_API_KEY` - Zalo TTS API (fallback)
- `HUGGINGFACE_ENDPOINT` - Custom endpoint (mặc định: https://router.huggingface.co/v1/chat/completions)
- `HUGGINGFACE_MODEL` - Custom model (mặc định: deepseek-ai/DeepSeek-V3.2-Exp)

**Cách chạy thủ công:**

1. Vào tab **Actions**
2. Chọn workflow **Process Videos from Database to R2**
3. Click **Run workflow**
4. Click **Run workflow** để xác nhận

---

## 3. 📁 Merge Videos (Legacy)

**File:** `merge-videos.yml`

**Mục đích:** Xử lý video từ file JSON (phương pháp cũ).

**Trạng thái:** Legacy - khuyến nghị dùng workflow #2 thay thế

**Khi nào dùng:**
- Test/debug với dữ liệu cụ thể trong file JSON
- Xử lý một lần với input file

---

## Thứ tự khuyến nghị khi setup repository:

### Lần đầu setup:

1. **Cấu hình GitHub Secrets** (xem hướng dẫn trong README.md chính)

2. **Chạy Migration** (một lần)
   ```
   Actions → Run Database Migration → nhập "migrate" → Run workflow
   ```

3. **Chạy Video Processing** (tự động hoặc thủ công)
   ```
   Actions → Process Videos from Database to R2 → Run workflow
   ```

### Sau khi setup:

- Workflow #2 sẽ tự động chạy mỗi giờ
- Hoặc trigger thủ công khi cần

---

## Troubleshooting

### Migration fails

**Lỗi:** `DATABASE_URL not found`
- **Giải pháp:** Kiểm tra GitHub Secret `DATABASE_URL` đã được cấu hình

**Lỗi:** `permission denied`
- **Giải pháp:** Database user cần quyền `ALTER TABLE` trên bảng products

**Lỗi:** `relation "products" does not exist`
- **Giải pháp:** Tạo bảng products trước (xem README.md chính)

### Video Processing fails

**Lỗi:** `No pending products to process`
- **Giải pháp:** Đảm bảo có products với `merge_status=FALSE` trong database

**Lỗi:** `R2 upload failed`
- **Giải pháp:** Kiểm tra R2 credentials và bucket permissions

**Lỗi:** `Edge-TTS authentication error`
- **Giải pháp:** Script sẽ tự động fallback sang Zalo TTS nếu có `ZALO_API_KEY`

---

## Monitoring

Để theo dõi workflows:

1. Vào tab **Actions** trong repository
2. Chọn workflow run để xem logs chi tiết
3. Kiểm tra **Summary** để xem tổng quan kết quả
4. Xem **Logs** của từng step để debug nếu cần

---

## Best Practices

1. ✅ Chạy migration trước khi chạy video processing
2. ✅ Kiểm tra logs sau mỗi workflow run
3. ✅ Backup database trước khi chạy migration (production)
4. ✅ Test với một vài products trước khi scale up
5. ✅ Monitor R2 storage usage
