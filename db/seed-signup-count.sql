ALTER TABLE public.prayer_requests ADD COLUMN IF NOT EXISTS is_seed boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.prayer_requests.is_seed IS 'Admin-supplied pool names are true and excluded from signup counts. Website submissions default to false.';
CREATE OR REPLACE FUNCTION public.get_signup_count() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('count',count(*)) FROM public.prayer_requests WHERE NOT is_seed;
$$;