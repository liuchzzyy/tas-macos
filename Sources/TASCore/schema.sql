CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filename TEXT NOT NULL,
        hash TEXT NOT NULL,
        original_size INTEGER NOT NULL,
        stored_size INTEGER NOT NULL,
        chunks INTEGER NOT NULL DEFAULT 1,
        compressed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);
      CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash);


      CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        message_id TEXT NOT NULL,
        file_telegram_id TEXT,
        bot_id TEXT,
        size INTEGER NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
        UNIQUE(file_id, chunk_index)
      );



      CREATE TABLE IF NOT EXISTS tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL,
        tag TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
        UNIQUE(file_id, tag)
      );

      CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);


      CREATE TABLE IF NOT EXISTS sync_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_path TEXT UNIQUE NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );


      CREATE TABLE IF NOT EXISTS sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder_id INTEGER NOT NULL,
        relative_path TEXT NOT NULL,
        file_hash TEXT,
        mtime INTEGER,
        synced_at TEXT,
        FOREIGN KEY (folder_id) REFERENCES sync_folders(id) ON DELETE CASCADE,
        UNIQUE(folder_id, relative_path)
      );


      CREATE TABLE IF NOT EXISTS shares (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL,
        token TEXT UNIQUE NOT NULL,
        expires_at TEXT NOT NULL,
        max_downloads INTEGER NOT NULL DEFAULT 1,
        download_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      );

      CREATE INDEX IF NOT EXISTS idx_shares_token ON shares(token);


      CREATE TABLE IF NOT EXISTS pending_uploads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filename TEXT NOT NULL,
        file_path TEXT NOT NULL,
        hash TEXT NOT NULL,
        original_size INTEGER NOT NULL,
        stored_size INTEGER NOT NULL DEFAULT 0,
        compressed INTEGER NOT NULL DEFAULT 0,
        total_chunks INTEGER NOT NULL,
        uploaded_chunks INTEGER NOT NULL DEFAULT 0,
        temp_dir TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE TABLE IF NOT EXISTS pending_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pending_id INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk_path TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0,
        message_id TEXT,
        file_telegram_id TEXT,
        bot_id TEXT,
        size INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (pending_id) REFERENCES pending_uploads(id) ON DELETE CASCADE,
        UNIQUE(pending_id, chunk_index)
      );
