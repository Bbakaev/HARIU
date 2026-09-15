-- Individual name allocation. Existing paired requests keep their original matches.
ALTER TABLE public.prayer_requests ADD COLUMN IF NOT EXISTS prayer_capacity integer NOT NULL DEFAULT 1 CHECK (prayer_capacity BETWEEN 1 AND 4);
CREATE SCHEMA IF NOT EXISTS hariu_private;
REVOKE ALL ON SCHEMA hariu_private FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS hariu_private.name_assignments (
  recipient_id uuid NOT NULL REFERENCES public.prayer_requests(id),
  source_id uuid NOT NULL REFERENCES public.prayer_requests(id),
  source_index integer NOT NULL CHECK (source_index BETWEEN 0 AND 4),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_id, source_index),
  CHECK (recipient_id <> source_id)
);
CREATE INDEX IF NOT EXISTS name_assignments_recipient_idx ON hariu_private.name_assignments(recipient_id);
ALTER TABLE hariu_private.name_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON hariu_private.name_assignments FROM PUBLIC, anon, authenticated;

-- Caller holds the shared transaction lock. All allocations are append-only.
CREATE OR REPLACE FUNCTION hariu_private.allocate_names() RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE target record; candidate record; slots integer;
BEGIN
  FOR target IN
    SELECT r.id, r.prayer_capacity FROM public.prayer_requests r
    WHERE r.matched_request_id IS NULL AND r.created_at >= now() - interval '48 hours'
      AND (SELECT count(*) FROM hariu_private.name_assignments a WHERE a.recipient_id=r.id) < r.prayer_capacity
    ORDER BY r.created_at, r.id
  LOOP
    SELECT target.prayer_capacity - count(*)::integer INTO slots
    FROM hariu_private.name_assignments WHERE recipient_id=target.id;
    FOR candidate IN
      SELECT r.id, (n.ordinality-1)::integer AS name_index
      FROM public.prayer_requests r
      CROSS JOIN LATERAL jsonb_array_elements(r.names) WITH ORDINALITY n(item,ordinality)
      WHERE r.id <> target.id AND r.matched_request_id IS NULL
        AND r.created_at >= now() - interval '48 hours'
        AND NOT EXISTS (SELECT 1 FROM hariu_private.name_assignments a WHERE a.source_id=r.id AND a.source_index=n.ordinality-1)
      ORDER BY r.created_at, r.id, n.ordinality LIMIT slots
    LOOP
      INSERT INTO hariu_private.name_assignments(recipient_id,source_id,source_index)
      VALUES(target.id,candidate.id,candidate.name_index);
    END LOOP;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION hariu_private.allocate_names() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_match(p_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE current_request public.prayer_requests%rowtype; entries jsonb; received integer; pending integer;
BEGIN
  SELECT * INTO current_request FROM public.prayer_requests WHERE claim_token=p_token;
  IF current_request.id IS NULL THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF current_request.matched_request_id IS NOT NULL THEN
    RETURN jsonb_build_object('status','paired','match',public.hariu_public_match(current_request.matched_request_id),'pending',0);
  END IF;
  IF current_request.created_at >= now() - interval '48 hours' THEN
    PERFORM pg_advisory_xact_lock(734192608);
    PERFORM hariu_private.allocate_names();
  END IF;
  SELECT coalesce(jsonb_agg(
    jsonb_build_object('firstName',r.names->a.source_index->>'firstName',
      'motherName',r.names->a.source_index->>'motherName',
      'gender',r.names->a.source_index->>'gender',
      'prayerType',coalesce(r.names->a.source_index->>'prayerType',r.prayer_type),
      'details',coalesce(r.names->a.source_index->>'details',r.details))
    ORDER BY a.created_at,a.source_id,a.source_index),'[]'::jsonb)
  INTO entries FROM hariu_private.name_assignments a JOIN public.prayer_requests r ON r.id=a.source_id
  WHERE a.recipient_id=current_request.id;
  received := jsonb_array_length(entries);
  pending := CASE WHEN current_request.created_at < now()-interval '48 hours' THEN 0 ELSE greatest(0,current_request.prayer_capacity-received) END;
  RETURN jsonb_build_object('status',CASE WHEN received>0 THEN 'paired' WHEN pending=0 THEN 'expired' ELSE 'waiting' END,
    'match',jsonb_build_object('names',entries,'prayerType','Individual prayer requests','details',''),
    'capacity',current_request.prayer_capacity,'pending',pending);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_and_match_v2(p_token uuid,p_names jsonb,p_prayer_type text,p_details text DEFAULT '',p_capacity integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean_names jsonb;
BEGIN
  IF p_token IS NULL THEN RAISE EXCEPTION 'Missing claim token'; END IF;
  IF p_capacity IS NULL OR p_capacity NOT BETWEEN 1 AND 4 THEN RAISE EXCEPTION 'Choose between 1 and 4 people to daven for.'; END IF;
  IF p_names IS NULL OR jsonb_typeof(p_names) <> 'array' THEN RAISE EXCEPTION 'Please provide 1-4 valid Hebrew names.'; END IF;
  IF jsonb_array_length(p_names) NOT BETWEEN 1 AND 4 OR NOT public.hariu_validate_names(p_names) THEN RAISE EXCEPTION 'Please provide 1-4 valid Hebrew names.'; END IF;
  p_prayer_type := trim(coalesce(p_prayer_type,'')); p_details := trim(coalesce(p_details,''));
  IF char_length(p_prayer_type) NOT BETWEEN 1 AND 60 OR char_length(p_details)>320 THEN RAISE EXCEPTION 'Prayer request is invalid.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
    WHERE char_length(trim(coalesce(n->>'prayerType',p_prayer_type))) NOT BETWEEN 1 AND 60
       OR char_length(coalesce(n->>'details',p_details))>320) THEN RAISE EXCEPTION 'Each name needs a prayer category and a message of at most 320 characters.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('firstName',trim(n->>'firstName'),'motherName',trim(n->>'motherName'),'gender',n->>'gender',
    'prayerType',trim(coalesce(n->>'prayerType',p_prayer_type)),'details',trim(coalesce(n->>'details',p_details))) ORDER BY position)
  INTO clean_names FROM jsonb_array_elements(p_names) WITH ORDINALITY t(n,position);
  PERFORM pg_advisory_xact_lock(734192608);
  INSERT INTO public.prayer_requests(claim_token,names,prayer_type,details,prayer_capacity)
  VALUES(p_token,clean_names,p_prayer_type,p_details,p_capacity) ON CONFLICT(claim_token) DO NOTHING;
  RETURN public.get_match(p_token);
END;
$$;

-- Existing browser tabs use this signature; share the same allocator.
CREATE OR REPLACE FUNCTION public.submit_and_match(p_token uuid,p_names jsonb,p_prayer_type text,p_details text DEFAULT '')
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.submit_and_match_v2(p_token,p_names,p_prayer_type,p_details,1);
$$;
REVOKE ALL ON FUNCTION public.submit_and_match_v2(uuid,jsonb,text,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_and_match_v2(uuid,jsonb,text,text,integer) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.get_match(uuid), public.submit_and_match(uuid,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_match(uuid), public.submit_and_match(uuid,jsonb,text,text) TO anon,authenticated,service_role;
