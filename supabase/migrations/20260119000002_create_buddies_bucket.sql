-- Create the buddies storage bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'buddies',
    'buddies',
    true,
    52428800, -- 50MB limit
    ARRAY['model/vnd.usdz+zip', 'application/octet-stream']
)
ON CONFLICT (id) DO NOTHING;

-- Allow public read access to the buddies bucket
DROP POLICY IF EXISTS "Public read access for buddies" ON storage.objects;
CREATE POLICY "Public read access for buddies"
ON storage.objects FOR SELECT
USING (bucket_id = 'buddies');

-- Allow authenticated users to upload to buddies bucket (for admin purposes)
DROP POLICY IF EXISTS "Authenticated users can upload to buddies" ON storage.objects;
CREATE POLICY "Authenticated users can upload to buddies"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'buddies');
