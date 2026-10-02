CREATE POLICY "Members upload own diagnostika videos"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'diagnostika' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Members read own diagnostika videos"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'diagnostika' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.has_role(auth.uid(), 'admin')));

CREATE POLICY "Members delete own diagnostika videos"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'diagnostika' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.has_role(auth.uid(), 'admin')));