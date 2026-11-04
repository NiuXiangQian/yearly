-- MySQL 5.7.8+ / InnoDB / utf8mb4. Select the target database first.

-- Alternative to Alembic. After importing, stamp revision 0006.

SET NAMES utf8mb4;


CREATE TABLE captcha (
	id VARCHAR(64) NOT NULL,
	answer_hash VARCHAR(64) NOT NULL,
	expires_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_captcha_expires_at ON captcha (expires_at);


CREATE TABLE child (
	id BIGINT NOT NULL AUTO_INCREMENT,
	name VARCHAR(80) NOT NULL,
	nickname VARCHAR(80) NOT NULL,
	avatar_media_id BIGINT,
	profile_type VARCHAR(16) NOT NULL DEFAULT 'child',
	relationship VARCHAR(80) NOT NULL DEFAULT '',
	species VARCHAR(80) NOT NULL DEFAULT '',
	breed VARCHAR(80) NOT NULL DEFAULT '',
	birthday DATE,
	birth_time TIME,
	gender VARCHAR(24),
	description TEXT NOT NULL,
	theme_color VARCHAR(7) NOT NULL,
	sort_order INTEGER NOT NULL,
	status VARCHAR(16) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_child_status ON child (status);


CREATE TABLE login_guard (
	`key` VARCHAR(64) NOT NULL,
	failures INTEGER NOT NULL,
	reset_at DATETIME(3) NOT NULL,
	PRIMARY KEY (`key`)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_login_guard_reset_at ON login_guard (reset_at);


CREATE TABLE sys_user (
	id BIGINT NOT NULL AUTO_INCREMENT,
	username VARCHAR(80) NOT NULL,
	password_hash VARCHAR(255) NOT NULL,
	`role` VARCHAR(16) NOT NULL,
	active BOOL NOT NULL,
	created_at DATETIME(3) NOT NULL,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (username)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;


CREATE TABLE media (
	id BIGINT NOT NULL AUTO_INCREMENT,
	owner_id BIGINT NOT NULL,
	media_type VARCHAR(16) NOT NULL,
	title VARCHAR(255) NOT NULL,
	batch_name VARCHAR(255) NOT NULL DEFAULT '',
	timeline_date DATE,
	sort_order INTEGER NOT NULL DEFAULT '0',
	remark TEXT NOT NULL,
	tags JSON NOT NULL,
	original_taken_at_local DATETIME(3),
	original_offset_minutes INTEGER,
	original_time_source VARCHAR(64) NOT NULL,
	corrected_taken_at_local DATETIME(3),
	corrected_offset_minutes INTEGER,
	taken_at_local DATETIME(3),
	taken_at_utc DATETIME(3),
	taken_offset_minutes INTEGER,
	time_source VARCHAR(64) NOT NULL,
	time_confidence VARCHAR(16) NOT NULL,
	time_unknown BOOL NOT NULL DEFAULT '0',
	latitude NUMERIC(10, 7),
	longitude NUMERIC(10, 7),
	altitude NUMERIC(12, 3),
	location_name VARCHAR(255) NOT NULL,
	width INTEGER,
	height INTEGER,
	duration_ms BIGINT,
	device_make VARCHAR(120),
	device_model VARCHAR(120),
	status VARCHAR(16) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(owner_id) REFERENCES sys_user (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_media_status_taken ON media (status, taken_at_local, id);

CREATE INDEX ix_media_taken_at_local ON media (taken_at_local);


CREATE TABLE user_session (
	id VARCHAR(64) NOT NULL,
	user_id BIGINT NOT NULL,
	csrf_token VARCHAR(64) NOT NULL,
	expires_at DATETIME(3) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(user_id) REFERENCES sys_user (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_user_session_user_id ON user_session (user_id);

CREATE INDEX ix_user_session_expires_at ON user_session (expires_at);


CREATE TABLE media_child (
	id BIGINT NOT NULL AUTO_INCREMENT,
	media_id BIGINT NOT NULL,
	child_id BIGINT NOT NULL,
	created_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_media_child UNIQUE (media_id, child_id),
	FOREIGN KEY(media_id) REFERENCES media (id),
	FOREIGN KEY(child_id) REFERENCES child (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_media_child_media_id ON media_child (media_id);

CREATE INDEX ix_child_media ON media_child (child_id, media_id);


CREATE TABLE media_file (
	id BIGINT NOT NULL AUTO_INCREMENT,
	media_id BIGINT NOT NULL,
	file_role VARCHAR(24) NOT NULL,
	oss_bucket VARCHAR(100) NOT NULL,
	oss_object_key VARCHAR(191) NOT NULL,
	original_filename VARCHAR(255) NOT NULL,
	mime_type VARCHAR(120) NOT NULL,
	file_size BIGINT NOT NULL,
	sha256 VARCHAR(64) NOT NULL,
	crc64 VARCHAR(20) NOT NULL,
	upload_status VARCHAR(16) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(media_id) REFERENCES media (id),
	UNIQUE (oss_object_key)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_media_file_media_id ON media_file (media_id);

CREATE INDEX ix_media_file_sha256 ON media_file (sha256);


CREATE TABLE media_metadata (
	media_id BIGINT NOT NULL,
	raw_metadata JSON NOT NULL,
	parser_name VARCHAR(120) NOT NULL,
	parser_version VARCHAR(80) NOT NULL,
	parse_status VARCHAR(24) NOT NULL,
	parse_error TEXT,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (media_id),
	FOREIGN KEY(media_id) REFERENCES media (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;


CREATE TABLE timeline_event (
	id BIGINT NOT NULL AUTO_INCREMENT,
	title VARCHAR(255) NOT NULL,
	content TEXT NOT NULL,
	start_at DATETIME(3),
	end_at DATETIME(3),
	cover_media_id BIGINT,
	created_by BIGINT NOT NULL,
	status VARCHAR(16) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(cover_media_id) REFERENCES media (id),
	FOREIGN KEY(created_by) REFERENCES sys_user (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_timeline_event_status ON timeline_event (status);

CREATE INDEX ix_timeline_event_start_at ON timeline_event (start_at);


CREATE TABLE timeline_event_child (
	event_id BIGINT NOT NULL,
	child_id BIGINT NOT NULL,
	PRIMARY KEY (event_id, child_id),
	FOREIGN KEY(event_id) REFERENCES timeline_event (id),
	FOREIGN KEY(child_id) REFERENCES child (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_timeline_event_child_child_id ON timeline_event_child (child_id);


CREATE TABLE timeline_event_media (
	event_id BIGINT NOT NULL,
	media_id BIGINT NOT NULL,
	sort_order INTEGER NOT NULL,
	PRIMARY KEY (event_id, media_id),
	FOREIGN KEY(event_id) REFERENCES timeline_event (id),
	FOREIGN KEY(media_id) REFERENCES media (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_timeline_event_media_media_id ON timeline_event_media (media_id);


CREATE TABLE upload_task (
	id VARCHAR(36) NOT NULL,
	owner_id BIGINT NOT NULL,
	media_id BIGINT NOT NULL,
	file_id BIGINT NOT NULL,
	oss_upload_id VARCHAR(255),
	part_size INTEGER NOT NULL,
	status VARCHAR(24) NOT NULL,
	expires_at DATETIME(3) NOT NULL,
	created_at DATETIME(3) NOT NULL,
	updated_at DATETIME(3) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(owner_id) REFERENCES sys_user (id),
	FOREIGN KEY(media_id) REFERENCES media (id),
	UNIQUE (file_id),
	FOREIGN KEY(file_id) REFERENCES media_file (id)
)CHARSET=utf8mb4 ENGINE=InnoDB COLLATE utf8mb4_unicode_ci

;

CREATE INDEX ix_upload_task_expires_at ON upload_task (expires_at);

CREATE INDEX ix_upload_task_media_id ON upload_task (media_id);

CREATE INDEX ix_upload_task_owner_id ON upload_task (owner_id);

CREATE INDEX ix_upload_status_updated ON upload_task (status, updated_at);

ALTER TABLE child ADD CONSTRAINT fk_child_avatar FOREIGN KEY(avatar_media_id) REFERENCES media (id);

CREATE TABLE video_preview (
  sha256 VARCHAR(64) NOT NULL PRIMARY KEY,
  status VARCHAR(16) NOT NULL,
  object_key VARCHAR(191) NOT NULL,
  file_size BIGINT NOT NULL,
  error VARCHAR(255) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


CREATE TABLE timeline_folder (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  timeline_date DATE NOT NULL,
  sort_order INTEGER NOT NULL,
  status VARCHAR(16) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  INDEX ix_timeline_folder_timeline_date (timeline_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE media ADD COLUMN folder_id BIGINT NULL,
  ADD INDEX ix_media_folder_id (folder_id),
  ADD CONSTRAINT fk_media_folder FOREIGN KEY (folder_id) REFERENCES timeline_folder (id);

ALTER TABLE media ADD COLUMN purpose VARCHAR(16) NOT NULL DEFAULT 'memory';

CREATE TABLE timeline_share (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  token_hash VARCHAR(64) NOT NULL UNIQUE,
  created_by BIGINT NOT NULL,
  title VARCHAR(120) NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  expires_at DATETIME(3) NOT NULL,
  revoked BOOLEAN NOT NULL,
  created_at DATETIME(3) NOT NULL,
  INDEX ix_timeline_share_created_by (created_by),
  FOREIGN KEY (created_by) REFERENCES sys_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE media ADD COLUMN share_allowed BOOLEAN NOT NULL DEFAULT 1;
ALTER TABLE timeline_folder ADD COLUMN share_allowed BOOLEAN NOT NULL DEFAULT 1;
ALTER TABLE timeline_event ADD COLUMN share_allowed BOOLEAN NOT NULL DEFAULT 1;
CREATE TABLE timeline_day (
  timeline_date DATE NOT NULL PRIMARY KEY,
  share_allowed BOOLEAN NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
