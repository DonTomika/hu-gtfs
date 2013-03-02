-- CREATE INDEX plo_lri ON planet_osm_line USING btree (line_relation_id);

BEGIN;

DROP FUNCTION IF EXISTS PT_LineDirection(base geometry, the_geom geometry);
DROP FUNCTION IF EXISTS PT_DirectionalIntersection(geomA geometry, geomB geometry);
DROP FUNCTION IF EXISTS PT_line_direction_on_way(lineid text, the_geom geometry);
DROP FUNCTION IF EXISTS PT_handle_site_relations();
DROP FUNCTION IF EXISTS PT_copy_metadata();
DROP FUNCTION IF EXISTS PT_mark_final_stations();
DROP FUNCTION IF EXISTS PT_create_labeling();
DROP FUNCTION IF EXISTS PT_fill_labeling();

CREATE FUNCTION PT_LineDirection(base geometry, the_geom geometry)
  RETURNS character AS
$BODY$
DECLARE
	l boolean;
	r boolean;
	simplegeom record;
BEGIN
	IF GeometryType(the_geom) = 'LINESTRING' AND GeometryType(base) = 'LINESTRING'
	   AND ST_NumPoints(the_geom) >= 2 AND ST_NumPoints(base) >= 2 THEN
		--IF ST_PointN(the_geom, 1) = ST_PointN(base, 1) AND ST_PointN(the_geom, 2) = ST_PointN(base, 2) -- ST_OrderingEquals(base, the_geom)
		IF ST_OrderingEquals(base, the_geom)
		THEN
			RETURN 'right';
		ELSE
			RETURN 'left';
		END IF;
	END IF;

	IF GeometryType(the_geom) = 'MULTILINESTRING' THEN
		l := false;
		r := false;
		FOR simplegeom IN SELECT (ST_Dump(the_geom)).geom LOOP
			IF PT_LineDirection(base, simplegeom.geom) = 'left' THEN
				l = true;
			ELSIF PT_LineDirection(base, simplegeom.geom) = 'right' THEN
				r = true;
			END IF;
		END LOOP;
		IF l AND r THEN
			RETURN 'both';
		ELSIF l THEN
			RETURN 'left';
		ELSIF r THEN
			RETURN 'right';
		END IF;
	END IF;

	RETURN 'dunno';
END
$BODY$
  LANGUAGE 'plpgsql' IMMUTABLE COST 1;

CREATE FUNCTION PT_DirectionalIntersection(geomA geometry, geomB geometry) RETURNS geometry AS $$
DECLARE
	i bigint;
	j bigint;
	d bigint;
	na bigint;
	nb bigint;
	happy boolean;
	result geometry;
	sp geometry;
	ep geometry;
BEGIN
	IF ST_NumPoints(geomA) < 2 OR ST_NumPoints(geomB) < 2 OR NOT(geomA && geomB) THEN
		return result;
	END IF;

	i := 1;
	ep := ST_EndPoint(geomB);
	sp := ST_StartPoint(geomB);
	na := ST_NumPoints(geomA);
	nb := ST_NumPoints(geomB);
	d := na - nb + 1;
	WHILE i <= d LOOP
		IF          sp = ST_PointN(geomA, i)
			AND ep = ST_PointN(geomA, i + nb - 1)
		THEN
			happy := true;
			FOR j IN 1 .. nb LOOP
				IF NOT(ST_PointN(geomA, i + j - 1) = ST_PointN(geomB, j))
				THEN BEGIN
					happy := false;
					exit;
				END;
				END IF;
			END LOOP;

			IF happy THEN
				result := ST_Collect(result, geomB);
				i := i + nb;
				CONTINUE;
			END IF;
		END IF;

		IF          ep   = ST_PointN(geomA, i)
			AND sp = ST_PointN(geomA, i + nb - 1)
		THEN
			happy := true;
			FOR j IN 1 .. nb LOOP
				IF NOT(ST_PointN(geomA, i + j - 1) = ST_PointN(geomB, nb - j + 1)) THEN
				BEGIN
					happy := false;
					exit;
				END;
				END IF;
			END LOOP;

			IF happy THEN
				result := ST_Collect(result, ST_Reverse(geomB));
				i := i + nb;
				CONTINUE;
			END IF;
		END IF;

		i := i + 1;
	END LOOP;

	RETURN result;
END
$$ LANGUAGE plpgsql IMMUTABLE COST 100;

CREATE FUNCTION PT_line_direction_on_way(lineid text, the_geom geometry) RETURNS text AS $$
DECLARE
	l boolean;
	r boolean;
	b boolean;
	rec record;
BEGIN
	l := false;
	r := false;
	b := false;

	FOR rec IN
		SELECT DISTINCT PT_LineDirection(the_geom, PT_DirectionalIntersection(way, the_geom)) AS dir
		FROM planet_osm_line
		WHERE line_relation_id = lineid
	LOOP
		IF rec.dir = 'left' THEN l := true;
		ELSIF rec.dir = 'right' THEN r := true;
		ELSIF rec.dir = 'both' THEN b := true;
		END IF;
	END LOOP;

	IF b OR (l AND r) THEN return 'both'; END IF;
	IF l THEN return 'left'; END IF;
	IF r THEN return 'right'; END IF;
	return 'dunno';
END
$$ LANGUAGE plpgsql COST 100;

CREATE FUNCTION PT_fill_labeling() RETURNS bigint AS $$
DECLARE
BEGIN
	TRUNCATE TABLE public_transit_labeling;

	INSERT INTO public_transit_labeling
		SELECT DISTINCT
			l.operator AS operator,
			l.line_variant AS line_variant,
			l.line_relation_id AS line_relation_id,
			l.ref AS ref,
			PT_line_direction_on_way(l.line_relation_id, r.way) AS direction,
			r.way AS way
		FROM
			planet_osm_line r, planet_osm_line l
		WHERE
			l.line_variant IS NOT NULL
			AND r.line_variant IS NULL
			AND r.osm_id > 0 -- relations have a negative id
			AND ST_Length(r.way) > 40
			AND ST_Intersects(l.way, r.way)
			AND ST_Within(r.way, l.way);

	-- split ways into short segments -> recalculate non-both/dunno directions

	ANALYZE public_transit_labeling;
	RETURN 1;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION PT_create_labeling() RETURNS bigint AS $$
DECLARE
BEGIN
	DROP TABLE IF EXISTS public_transit_labeling CASCADE;

	CREATE TABLE public_transit_labeling (operator text, line_variant text, line_relation_id text, ref text, direction text, way geometry);
	CREATE INDEX public_transit_labeling_index ON public_transit_labeling USING gist (way);

	--GRANT ALL ON TABLE public_transit_labeling TO osm_mapnik;
	GRANT SELECT ON TABLE public_transit_labeling TO public;

	RETURN 1;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION PT_copy_metadata() RETURNS bigint AS $$
DECLARE
	-- Create fake line_variant ways -> copy operator, line_variant, ref, line_variant_direction, r.way
	-- Copy refs -> halt -> group -> interchange
BEGIN
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION PT_mark_final_stations() RETURNS bigint AS $$
DECLARE
	rec record;
	subrec record;
	next_id bigint;
BEGIN


	RETURN 1;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION PT_handle_site_relations() RETURNS bigint AS $$
DECLARE
	rec record;
	subrec record;
	next_id bigint;
	site_type text;

	a_geom geometry;
	t_geom geometry;
	i bigint;
	n_operator text;
	n_ref text;
	n_name text;
	n_alt_name text;
	n_old_name text;
	n_alt_old_name text;

BEGIN
	-- Delete generated site polygons, reset data
	DELETE FROM planet_osm_polygon WHERE site_generated IS NOT NULL;
	DELETE FROM planet_osm_polygon WHERE site IS NOT NULL AND osm_id < 0;

	UPDATE planet_osm_point   SET site_generated = NULL, site_relation_id = NULL WHERE site_generated IS NOT NULL;
	UPDATE planet_osm_line    SET site_generated = NULL, site_relation_id = NULL WHERE site_generated IS NOT NULL;
	UPDATE planet_osm_polygon SET site_generated = NULL, site_relation_id = NULL WHERE site_generated IS NOT NULL;

	-- Process halt relations
	FOR rec IN SELECT * FROM planet_osm_rels WHERE tags @> ARRAY['type', 'site', 'site'] AND tags && ARRAY['stop', 'tram_stop', 'bus_stop', 'dock', 'apron'] LOOP
		a_geom := NULL;
		i := array_lower(rec.tags, 1);
		n_name := NULL; n_ref := NULL; n_operator := NULL; n_alt_name := NULL;
		WHILE  i < array_upper(rec.tags, 1) LOOP
			IF rec.tags[i] = 'site' THEN
				site_type := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'name' THEN
				n_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'alt_name' THEN
				n_alt_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'old_name' THEN
				n_old_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'alt_old_name' THEN
				n_alt_old_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'ref' THEN
				n_ref := rec.tags[i + 1];
			END IF;

			i := i + 2;
		END LOOP;

		-- Differentiate members sometime [platform/stop/entrance]
		i := array_lower(rec.members, 1);
		WHILE  i < array_upper(rec.members, 1) LOOP
			IF substr(rec.members[i], 1, 1) = 'n' THEN
				SELECT ST_Point(lon / 100, lat / 100) INTO t_geom FROM planet_osm_nodes WHERE id = substr(rec.members[i], 2)::bigint;
				t_geom := ST_SetSRID(t_geom, Find_SRID('public', 'planet_osm_line', 'way'));
				a_geom := ST_Collect(a_geom, t_geom);
				UPDATE planet_osm_point SET site_relation_id = rec.id WHERE osm_id = substr(rec.members[i], 2)::bigint;
			ELSIF substr(rec.members[i], 1, 1) = 'w' THEN
				IF EXISTS(SELECT * FROM planet_osm_polygon WHERE osm_id = substr(rec.members[i], 2)::bigint) THEN
					SELECT ST_Collect(a_geom, way) INTO a_geom FROM planet_osm_polygon WHERE osm_id = substr(rec.members[i], 2)::bigint;
					UPDATE planet_osm_polygon SET site_relation_id = rec.id WHERE osm_id = substr(rec.members[i], 2)::bigint;
				ELSIF EXISTS(SELECT * FROM planet_osm_line WHERE osm_id = substr(rec.members[i], 2)::bigint) THEN
					SELECT ST_Collect(a_geom, way) INTO a_geom FROM planet_osm_line WHERE osm_id = substr(rec.members[i], 2)::bigint;
					UPDATE planet_osm_line SET site_relation_id = rec.id WHERE osm_id = substr(rec.members[i], 2)::bigint;
				ELSE
					RAISE NOTICE 'Create way? %', substr(rec.members[i], 2);
				END IF;
			ELSIF substr(rec.members[i], 1, 1) = 'r' THEN -- presumes polygon...
				SELECT ST_Collect(a_geom, way) INTO a_geom FROM planet_osm_polygon WHERE -osm_id = substr(rec.members[i], 2)::bigint;
				UPDATE planet_osm_line SET site_relation_id = rec.id WHERE -osm_id = substr(rec.members[i], 2)::bigint;
			ELSE
				NULL; -- ???
			END IF;

			i := i + 2;
		END LOOP;
	
		a_geom := ST_Buffer(ST_ConvexHull(a_geom), 10);

		INSERT INTO planet_osm_polygon (osm_id, site, site_generated, operator, ref, name, alt_name, old_name, alt_old_name, way) VALUES (-rec.id, site_type, NULL, n_operator, n_ref, n_name, n_alt_name, n_old_name, n_alt_old_name, a_geom);
	END LOOP;

	next_id := MAX(osm_id) + 1000000 FROM planet_osm_polygon;

	-- Generate halt polygons
	FOR rec IN SELECT * FROM planet_osm_point WHERE (highway IN('bus_stop') OR railway IN('halt', 'station', 'tram_stop')) AND site_relation_id IS NULL LOOP
		IF rec.highway = 'bus_stop' THEN
			site_type := 'bus_stop';
		ELSIF rec.railway = 'tram_stop' THEN
			site_type := 'tram_stop';
		ELSIF rec.railway  = 'halt' THEN
			site_type := 'railway_halt';
		ELSIF rec.railway  = 'station' THEN
			site_type := 'railway_halt_station';
		ELSE
			site_type := 'halt';
		END IF;

		INSERT INTO planet_osm_polygon (osm_id, site, site_generated, highway, railway, operator, ref, name, alt_name, old_name, alt_old_name, way) VALUES (next_id, site_type, 'yes', rec.highway, rec.railway, rec.operator, rec.ref, rec.name, rec.alt_name, rec.old_name, rec.alt_old_name, ST_Difference(ST_Buffer(rec.way, 10), rec.way));
		UPDATE planet_osm_point SET site_relation_id = next_id, site_generated = 'yes' WHERE osm_id = rec.osm_id ;

		next_id := next_id + 1;
	END LOOP;

	-- Process group-of-stops relations
	FOR rec IN SELECT * FROM planet_osm_rels WHERE tags @> ARRAY['type', 'site', 'site'] AND tags && ARRAY['stops', 'railway_station', 'railway_halt', 'bus_station', 'ferry_terminal', 'airport'] LOOP
		a_geom := NULL;
		i := array_lower(rec.tags, 1);
		n_name := NULL; n_ref := NULL; n_operator := NULL; n_alt_name := NULL;
		WHILE  i < array_upper(rec.tags, 1) LOOP
			IF rec.tags[i] = 'site' THEN
				site_type := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'name' THEN
				n_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'alt_name' THEN
				n_alt_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'old_name' THEN
				n_old_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'alt_old_name' THEN
				n_alt_old_name := rec.tags[i + 1];
			ELSIF rec.tags[i] = 'ref' THEN
				n_ref := rec.tags[i + 1];
			END IF;

			i := i + 2;
		END LOOP;

		i := array_lower(rec.members, 1);
		WHILE  i < array_upper(rec.members, 1) LOOP
			IF rec.members[i + 1] = 'label' THEN
				CONTINUE;
			END IF;

			IF substr(rec.members[i], 1, 1) = 'n' THEN
				--SELECT p.way INTO t_geom FROM planet_osm_polygon p WHERE EXISTS(SELECT n.way FROM planet_osm_point n WHERE n.osm_id = substr(rec.members[i], 2)::bigint AND n.site_relation_id::bigint = p.osm_id);
				--a_geom := ST_Union(a_geom, t_geom);
				UPDATE planet_osm_polygon p SET site_relation_id = rec.id::text WHERE EXISTS(SELECT n.way FROM planet_osm_point n WHERE n.osm_id = substr(rec.members[i], 2)::bigint AND n.site_relation_id::bigint = p.osm_id);
			ELSIF substr(rec.members[i], 1, 1) = 'w' THEN
				NULL;
			ELSIF substr(rec.members[i], 1, 1) = 'r' THEN
				--SELECT ST_Union(a_geom, way) INTO a_geom FROM planet_osm_polygon WHERE -osm_id = substr(rec.members[i], 2)::bigint;
				UPDATE planet_osm_polygon SET site_relation_id = rec.id WHERE -osm_id = substr(rec.members[i], 2)::bigint;
			ELSE
				NULL; -- ???
			END IF;

			i := i + 2;
		END LOOP;

		a_geom := ST_ConvexHull((SELECT ST_Collect(way) FROM planet_osm_polygon WHERE site_relation_id::int = rec.id));

		IF a_geom IS NULL THEN
			CONTINUE;
		END IF;

		a_geom := ST_Buffer(a_geom, 20);
		a_geom := ST_Difference(a_geom, (SELECT ST_Union(way) FROM planet_osm_polygon WHERE site_relation_id::int = rec.id));
		--a_geom := ST_Difference(ST_Buffer(ST_ConvexHull(a_geom), 20), ST_SnapToGrid(a_geom, 20));

		INSERT INTO planet_osm_polygon (osm_id, site, site_generated, operator, ref, name, alt_name, old_name, alt_old_name, way) VALUES (-rec.id, site_type, NULL, n_operator, n_ref, n_name, n_alt_name, n_old_name, n_alt_old_name, a_geom);
	END LOOP;
	next_id := MAX(osm_id) + 1000000 FROM planet_osm_polygon;

	-- Generate group-of-stop polygons for railway halts/stations
	FOR rec IN SELECT * FROM planet_osm_polygon WHERE site IN('railway_halt_station') AND site_relation_id IS NULL LOOP
		INSERT INTO planet_osm_polygon (osm_id, site, site_generated, name, alt_name, old_name, alt_old_name, way) VALUES (next_id, 'railway_station', 'yes', rec.name, rec.alt_name, rec.old_name, rec.alt_old_name, ST_Difference(ST_Buffer(rec.way, 20), rec.way));
		UPDATE planet_osm_polygon SET site_relation_id = next_id, site_generated = 'yes' WHERE osm_id = rec.osm_id ;
		next_id := next_id + 1;
	END LOOP;
	UPDATE planet_osm_polygon
		SET site = 'railway_halt'
		WHERE site = 'railway_halt_station';

	-- Generate group-of-stop polygons
	FOR rec IN
		SELECT *
		FROM planet_osm_polygon
		WHERE site IN('halt', 'bus_stop', 'tram_stop', 'stop', 'dock', 'apron', 'railway_halt') AND site_relation_id IS NULL
	LOOP
		SELECT * FROM planet_osm_polygon
			WHERE site IN('stops')
				AND osm_id > 0
				AND ST_DWithin(way, rec.way , 200)
				AND (          name IN(rec.name, rec.alt_name, rec.old_name, rec.alt_old_name)
					OR     alt_name IN(rec.name, rec.alt_name, rec.old_name, rec.alt_old_name)
					OR     old_name IN(rec.name, rec.alt_name, rec.old_name, rec.alt_old_name)
					OR alt_old_name IN(rec.name, rec.alt_name, rec.old_name, rec.alt_old_name))
			INTO subrec;

		IF found THEN
			UPDATE planet_osm_polygon
				SET site_relation_id = subrec.osm_id, site_generated = 'yes'
				WHERE osm_id = rec.osm_id ;

			a_geom := ST_ConvexHull((SELECT ST_Collect(way) FROM planet_osm_polygon WHERE site_relation_id::int = subrec.osm_id));
			a_geom := ST_Buffer(a_geom, 20);
			a_geom := ST_Difference(a_geom, (SELECT ST_Union(way) FROM planet_osm_polygon WHERE site_relation_id::int = subrec.osm_id));
			UPDATE planet_osm_polygon
				SET way = a_geom
				WHERE osm_id = subrec.osm_id;
		ELSE
			INSERT INTO planet_osm_polygon (osm_id, site, site_generated, name, alt_name, old_name, alt_old_name, way) VALUES (next_id, 'stops', 'yes', rec.name, rec.alt_name, rec.old_name, rec.alt_old_name, ST_Difference(ST_Buffer(rec.way, 20), rec.way));
			UPDATE planet_osm_polygon
				SET site_relation_id = next_id, site_generated = 'yes'
				WHERE osm_id = rec.osm_id;
			next_id := next_id + 1;
		END IF;
	END LOOP;

	FOR rec IN
		SELECT p1.osm_id AS id1, p1.way AS geom1, p2.osm_id AS id2, p2.osm_id AS geom2
		FROM planet_osm_polygon AS p1, planet_osm_polygon AS p2
		WHERE ST_DWithin(p1.way, p2.way, 200)
			AND p1.site_generated = 'yes' AND p2.site_generated = 'yes'
			AND p1.site = 'stops' AND p2.site = 'stops'
			AND (          p1.name IN(p2.name, p2.alt_name, p2.old_name, p2.alt_old_name)
				OR     p1.alt_name IN(p2.name, p2.alt_name, p2.old_name, p2.alt_old_name)
				OR     p1.old_name IN(p2.name, p2.alt_name, p2.old_name, p2.alt_old_name)
				OR p1.alt_old_name IN(p2.name, p2.alt_name, p2.old_name, p2.alt_old_name))
			AND p1.osm_id < p2.osm_id
	LOOP
		a_geom := ST_ConvexHull((SELECT ST_Collect(way) FROM planet_osm_polygon WHERE site_relation_id::int IN (rec.id1, rec.id2)));
		a_geom := ST_Buffer(a_geom, 20);
		a_geom := ST_Difference(a_geom, (SELECT ST_Union(way) FROM planet_osm_polygon WHERE site_relation_id::int IN (rec.id1, rec.id2)));
		UPDATE planet_osm_polygon
			SET way = a_geom
			WHERE osm_id = rec.id1;
		UPDATE planet_osm_polygon
			SET site_relation_id = rec.id1::text
			WHERE site_relation_id = rec.id2::text;
		DELETE
			FROM planet_osm_polygon
			WHERE osm_id = rec.id2;
	END LOOP;

/*	FOR rec IN SELECT p1.way AS p1way, p2.way AS p2way, p1.osm_id AS p1osm_id, p2.osm_id AS p2osm_id FROM planet_osm_polygon p1, planet_osm_polygon p2 WHERE p1.site IN('stops') AND p1.osm_id > 0 AND p2.site IN('stops') AND p2.osm_id > 0 AND ST_Intersects(p1.way, p2.way) AND (p1.alt_name IN(p2.name, p2.alt_name) OR p1.name IN(p2.name, p2.alt_name)) AND p1.osm_id != p2.osm_id LOOP

		IF found THEN
			UPDATE planet_osm_polygon SET way = ST_ConvexHull(ST_Collect(p1way, p2way)) WHERE osm_id = p1osm_id;
			UPDATE planet_osm_polygon SET osm_relation_id = p1osm_id WHERE osm_relation_id = p2osm_id::text;
			DELETE FROM planet_osm_polygon WHERE osm_id = p2.osm_id;
		END IF;
	END LOOP; */

	-- Process transit_interchange relations

	RETURN 1;
END;
$$ LANGUAGE plpgsql;

COMMIT;

