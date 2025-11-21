-- Migration: Add r2_video_url and processed_at columns to products table
-- Date: 2025-11-15
-- Description: Add columns to track R2 video URLs and processing timestamps

-- Add r2_video_url column if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'products'
        AND column_name = 'r2_video_url'
    ) THEN
        ALTER TABLE public.products ADD COLUMN r2_video_url TEXT;
        RAISE NOTICE 'Column r2_video_url added successfully';
    ELSE
        RAISE NOTICE 'Column r2_video_url already exists, skipping';
    END IF;
END $$;

-- Add processed_at column if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'products'
        AND column_name = 'processed_at'
    ) THEN
        ALTER TABLE public.products ADD COLUMN processed_at TIMESTAMP;
        RAISE NOTICE 'Column processed_at added successfully';
    ELSE
        RAISE NOTICE 'Column processed_at already exists, skipping';
    END IF;
END $$;

-- Create index on processed_at for better query performance (optional but recommended)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
        AND tablename = 'products'
        AND indexname = 'idx_products_processed_at'
    ) THEN
        CREATE INDEX idx_products_processed_at ON public.products(processed_at);
        RAISE NOTICE 'Index idx_products_processed_at created successfully';
    ELSE
        RAISE NOTICE 'Index idx_products_processed_at already exists, skipping';
    END IF;
END $$;

-- Verify the columns were added
SELECT
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
    AND table_name = 'products'
    AND column_name IN ('r2_video_url', 'processed_at')
ORDER BY column_name;
