CREATE POLICY "Members read recipe photos" ON storage.objects
  FOR SELECT TO authenticated USING (bucket_id = 'recepty');

CREATE POLICY "Members upload own recipe photos" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'recepty' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Members update own recipe photos" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'recepty' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Members delete own recipe photos" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'recepty' AND (storage.foldername(name))[1] = auth.uid()::text);