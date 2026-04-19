-- Update the buddies bucket to allow zip MIME type (needed for USDZ files)
UPDATE storage.buckets
SET allowed_mime_types = ARRAY['model/vnd.usdz+zip', 'application/octet-stream', 'application/zip']
WHERE id = 'buddies';
