ALTER TABLE public.coaching_modules DROP CONSTRAINT IF EXISTS coaching_modules_module_number_check;
ALTER TABLE public.coaching_modules ADD CONSTRAINT coaching_modules_module_number_check CHECK (module_number >= 1 AND module_number <= 20);
ALTER TABLE public.module_progress DROP CONSTRAINT IF EXISTS module_progress_module_number_check;
ALTER TABLE public.module_progress ADD CONSTRAINT module_progress_module_number_check CHECK (module_number >= 1 AND module_number <= 20);