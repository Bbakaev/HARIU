-- Seed records supply names only and remain available until assigned.
CREATE OR REPLACE FUNCTION hariu_private.allocate_names()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE target record; candidate record; slots integer;
BEGIN
  FOR target IN
    SELECT r.id, r.prayer_capacity FROM public.prayer_requests r
    WHERE NOT r.is_seed AND r.matched_request_id IS NULL AND r.created_at >= now() - interval '48 hours'
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
        AND (r.is_seed OR r.created_at >= now() - interval '48 hours')
        AND NOT EXISTS (SELECT 1 FROM hariu_private.name_assignments a WHERE a.source_id=r.id AND a.source_index=n.ordinality-1)
      ORDER BY r.created_at, r.id, n.ordinality LIMIT slots
    LOOP
      INSERT INTO hariu_private.name_assignments(recipient_id,source_id,source_index)
      VALUES(target.id,candidate.id,candidate.name_index);
    END LOOP;
  END LOOP;
END;
$function$
;