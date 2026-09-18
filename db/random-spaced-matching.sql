-- Existing seed positions were initialized privately using their approved import order.
-- New names are appended in submission order. Each person's selections differ by at least four positions.
CREATE TABLE hariu_private.name_list_positions (
 source_id uuid NOT NULL REFERENCES public.prayer_requests(id),
 source_index integer NOT NULL CHECK(source_index BETWEEN 0 AND 4),
 list_position bigint NOT NULL UNIQUE CHECK(list_position>0),
 PRIMARY KEY(source_id,source_index)
);
ALTER TABLE hariu_private.name_list_positions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON hariu_private.name_list_positions FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION hariu_private.allocate_names() RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE target record; candidate record; slots integer; slot integer;
BEGIN
 -- Use the same lock as submission/polling; list positions never change or compact.
 PERFORM pg_advisory_xact_lock(734192608);
 INSERT INTO hariu_private.name_list_positions(source_id,source_index,list_position)
 SELECT r.id,(n.ordinality-1)::integer,
   (SELECT coalesce(max(list_position),0) FROM hariu_private.name_list_positions)
   +row_number() OVER(ORDER BY r.created_at,r.id,n.ordinality)
 FROM public.prayer_requests r
 CROSS JOIN LATERAL jsonb_array_elements(r.names) WITH ORDINALITY n(item,ordinality)
 WHERE NOT EXISTS(SELECT 1 FROM hariu_private.name_list_positions p WHERE p.source_id=r.id AND p.source_index=n.ordinality-1);
 FOR target IN
  SELECT r.id,r.prayer_capacity FROM public.prayer_requests r
  WHERE NOT r.is_seed AND r.matched_request_id IS NULL AND r.created_at>=now()-interval '48 hours'
   AND (SELECT count(*) FROM hariu_private.name_assignments a WHERE a.recipient_id=r.id)<r.prayer_capacity
  ORDER BY r.created_at,r.id
 LOOP
  SELECT target.prayer_capacity-count(*)::integer INTO slots FROM hariu_private.name_assignments WHERE recipient_id=target.id;
  FOR slot IN 1..slots LOOP
   SELECT r.id,p.source_index INTO candidate
   FROM hariu_private.name_list_positions p JOIN public.prayer_requests r ON r.id=p.source_id
   WHERE r.id<>target.id AND r.matched_request_id IS NULL
    AND (r.is_seed OR r.created_at>=now()-interval '48 hours')
    AND NOT EXISTS(SELECT 1 FROM hariu_private.name_assignments a WHERE a.source_id=p.source_id AND a.source_index=p.source_index)
    AND NOT EXISTS(
     SELECT 1 FROM hariu_private.name_assignments a
     JOIN hariu_private.name_list_positions previous ON previous.source_id=a.source_id AND previous.source_index=a.source_index
     WHERE a.recipient_id=target.id AND abs(previous.list_position-p.list_position)<=3
    )
   ORDER BY random() LIMIT 1;
   EXIT WHEN NOT FOUND;
   INSERT INTO hariu_private.name_assignments(recipient_id,source_id,source_index) VALUES(target.id,candidate.id,candidate.source_index);
  END LOOP;
 END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION hariu_private.allocate_names() FROM PUBLIC,anon,authenticated;