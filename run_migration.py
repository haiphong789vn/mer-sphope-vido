#!/usr/bin/env python3
"""
Database Migration Script
Runs SQL migrations to add r2_video_url and processed_at columns to products table
"""

import os
import sys
import psycopg2
from pathlib import Path
import logging

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def run_migration():
    """Run database migration"""
    try:
        # Get database URL from environment
        db_url = os.getenv('DATABASE_URL')
        if not db_url:
            logger.error("DATABASE_URL environment variable is required")
            logger.info("Please set DATABASE_URL in your environment or .env file")
            sys.exit(1)

        logger.info("Connecting to database...")
        conn = psycopg2.connect(db_url)
        conn.autocommit = False  # Use transaction
        cursor = conn.cursor()

        # Read migration file
        migration_file = Path(__file__).parent / 'migrations' / '001_add_video_columns.sql'

        if not migration_file.exists():
            logger.error(f"Migration file not found: {migration_file}")
            sys.exit(1)

        logger.info(f"Reading migration file: {migration_file}")
        with open(migration_file, 'r') as f:
            migration_sql = f.read()

        # Execute migration
        logger.info("Executing migration...")
        cursor.execute(migration_sql)

        # Commit transaction
        conn.commit()
        logger.info("✅ Migration completed successfully!")

        # Verify columns were added
        logger.info("\nVerifying columns...")
        cursor.execute("""
            SELECT
                column_name,
                data_type,
                is_nullable
            FROM information_schema.columns
            WHERE table_schema = 'public'
                AND table_name = 'products'
                AND column_name IN ('r2_video_url', 'processed_at')
            ORDER BY column_name;
        """)

        results = cursor.fetchall()
        if results:
            logger.info("\nColumns verified:")
            for row in results:
                logger.info(f"  - {row[0]}: {row[1]} (nullable: {row[2]})")
        else:
            logger.warning("Warning: Could not verify columns")

        # Close connection
        cursor.close()
        conn.close()

        logger.info("\n" + "=" * 50)
        logger.info("Migration completed successfully!")
        logger.info("=" * 50)

    except psycopg2.Error as e:
        logger.error(f"Database error: {e}")
        if 'conn' in locals():
            conn.rollback()
        sys.exit(1)
    except Exception as e:
        logger.error(f"Error: {e}")
        sys.exit(1)


def main():
    """Entry point"""
    logger.info("=" * 50)
    logger.info("Database Migration - Add Video Columns")
    logger.info("=" * 50)
    logger.info("")

    run_migration()


if __name__ == '__main__':
    main()
