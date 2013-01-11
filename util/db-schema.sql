BEGIN;

--CREATE DATABASE mytransit WITH TEMPLATE = template0 ENCODING = 'UTF8' LC_COLLATE = 'en_US.UTF-8' LC_CTYPE = 'en_US.UTF-8';


DROP TABLE IF EXISTS entity_gtfs_map;
DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS frequencies;
DROP TABLE IF EXISTS stop_times;
DROP TABLE IF EXISTS trip_features;
DROP TABLE IF EXISTS trip_features_desc;
DROP TABLE IF EXISTS trips;
DROP TABLE IF EXISTS stop_features;
DROP TABLE IF EXISTS stop_features_desc;
DROP TABLE IF EXISTS stops;
DROP TABLE IF EXISTS calendar_dates;
DROP TABLE IF EXISTS calendar_periods;
DROP TABLE IF EXISTS services;
DROP TABLE IF EXISTS routes;
DROP TABLE IF EXISTS agencies;
DROP TABLE IF EXISTS shape_points;
DROP TABLE IF EXISTS shapes;
DROP TABLE IF EXISTS entity_geom;

DROP FUNCTION IF EXISTS array_to_json(text[]);
DROP FUNCTION IF EXISTS service_period_active(text, date);
DROP FUNCTION IF EXISTS stops_update_geom();
DROP FUNCTION IF EXISTS entity_geom(text, boolean);
DROP FUNCTION IF EXISTS create_entity_geom(text, boolean);
DROP FUNCTION IF EXISTS create_entity_geom(text, boolean, geometry);
DROP FUNCTION IF EXISTS entity_update_geom();
DROP FUNCTION IF EXISTS shapes_update_geom();
DROP FUNCTION IF EXISTS entity_gtfs_map_insert();
DROP FUNCTION IF EXISTS entity_gtfs_map_update();
DROP FUNCTION IF EXISTS entity_gtfs_map_delete();
DROP FUNCTION IF EXISTS service_a_insert();
DROP FUNCTION IF EXISTS service_a_update();
DROP FUNCTION IF EXISTS service_a_delete();
DROP FUNCTION IF EXISTS service_b_insert();
DROP FUNCTION IF EXISTS service_b_update();
DROP FUNCTION IF EXISTS service_b_delete();
DROP FUNCTION IF EXISTS gtfs_departures(text, timestamp, timestamp);
DROP FUNCTION IF EXISTS gtfs_departures_complete(text, timestamp, timestamp);
DROP FUNCTION IF EXISTS entity_departures(text, timestamp, timestamp);
DROP FUNCTION IF EXISTS entity_departures(text, timestamp, timestamp, integer);
DROP FUNCTION IF EXISTS entity_departures(text);
DROP FUNCTION IF EXISTS entity_departures(text, integer);
DROP FUNCTION IF EXISTS entity_departures_(text, timestamp, timestamp);
DROP FUNCTION IF EXISTS entity_departures_(text, timestamp, timestamp, integer);
DROP FUNCTION IF EXISTS entity_geom_update_operator();

DROP TYPE IF EXISTS directions;
DROP TYPE IF EXISTS drop_off_types;
DROP TYPE IF EXISTS location_types;
DROP TYPE IF EXISTS pickup_types;
DROP TYPE IF EXISTS route_types;
DROP TYPE IF EXISTS service_exception_types;
DROP TYPE IF EXISTS entity_level_types;
DROP TYPE IF EXISTS transfer_types;
DROP TYPE IF EXISTS trip_departure;

CREATE TYPE location_types AS ENUM (
    'stop',
    'station',
    'entrance'
);

CREATE TYPE entity_level_types AS ENUM (
    'stop',
    'area',
    'interchange'
);

CREATE TABLE entity_geom (
	qgis_is_stupid serial,
    osm_entity_id character varying(200) NOT NULL,
    entity_lat real,
    entity_lon real,
    entity_level entity_level_types NOT NULL,
    entity_name character varying,
    entity_type character varying,
    entity_names character varying[],
    entity_operators character varying[],
    entity_gtfs_ids text[],
    entity_members character varying[],
    entity_polygon character varying[]
);
SELECT AddGeometryColumn('entity_geom', 'the_geom',       900913, 'GEOMETRY', 2);
SELECT AddGeometryColumn('entity_geom', 'the_geom_point', 900913, 'POINT',    2);

CREATE TABLE entity_gtfs_map (
    osm_entity_id character varying(200) NOT NULL,
    gtfs_id character varying(200) NOT NULL
);

CREATE TABLE stops (
    stop_id character varying(100) NOT NULL,
    stop_code character varying(20),
    stop_name character varying(100) NOT NULL,
    stop_desc text,
    zone_id character varying(100),
    stop_url text,
    parent_station character varying(100),
    location_type location_types,
    stop_lat real,
    stop_lon real,
    stop_osm_entity character varying(100)
);
SELECT AddGeometryColumn('stops', 'stop_geom', 900913, 'POINT', 2);

/* Convers an array to json. Used by the WFS to return entity names */
CREATE FUNCTION array_to_json(myarray text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
DECLARE
	ret text;
	counter integer;
BEGIN
	ret := '[';
	FOR counter IN array_lower(myarray, 1) .. array_upper(myarray, 1) LOOP
		IF counter != array_lower(myarray, 1) THEN
			ret := ret || ', ';
		END IF;
		ret := ret || '"' || myarray[counter] || '"';
	END LOOP;
	ret := ret || ']';

	RETURN ret;
END $$;

/* Trigger to keep the entity_gtfs_map up-to-date after an INSERT*/
CREATE FUNCTION entity_gtfs_map_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	i integer;
BEGIN
	FOR i IN array_lower(NEW.entity_gtfs_ids , 1) .. array_upper(NEW.entity_gtfs_ids , 1) LOOP
		INSERT INTO entity_gtfs_map (osm_entity_id, gtfs_id) VALUES (NEW.osm_entity_id, NEW.entity_gtfs_ids[i]);
	END LOOP;

	RETURN NEW;
END$$;

/* Trigger to keep the entity_gtfs_map up-to-date after an UPDATE */
CREATE FUNCTION entity_gtfs_map_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	i integer;
BEGIN
	DELETE FROM entity_gtfs_map WHERE osm_entity_id = OLD.osm_entity_id;

	FOR i IN array_lower(NEW.entity_gtfs_ids , 1) .. array_upper(NEW.entity_gtfs_ids , 1) LOOP
		INSERT INTO entity_gtfs_map (osm_entity_id, gtfs_id) VALUES (NEW.osm_entity_id, NEW.entity_gtfs_ids[i]);
	END LOOP;

	RETURN NEW;
END$$;

/* Trigger to keep the entity_gtfs_map up-to-date after a DELETE */
CREATE FUNCTION entity_gtfs_map_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	DELETE FROM entity_gtfs_map WHERE osm_entity_id = OLD.osm_entity_id;

	RETURN NEW;
END$$;

/* Trigger function to automatically update stop_geom */
CREATE FUNCTION stops_update_geom() RETURNS trigger
    LANGUAGE plpgsql IMMUTABLE
    AS $$BEGIN
	IF NEW.stop_lat IS NOT NULL AND NEW.stop_lon IS NOT NULL THEN
		NEW.stop_geom = ST_Transform(ST_SetSRID(ST_GeomFromText('POINT(' || NEW.stop_lat || ' ' || NEW.stop_lon || ')'), 4326), 900913);
	END IF;
	RETURN NEW;
END$$;

/* Create polygons for entities */
CREATE FUNCTION entity_update_geom() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	inner_geom geometry;
	polygon_geom geometry;
	primitive boolean := false;
	buffer float;
	geom_rec record;
BEGIN
	IF NEW.entity_lat IS NOT NULL AND NEW.entity_lon IS NOT NULL THEN
		NEW.the_geom_point = ST_Transform(ST_SetSRID(ST_GeomFromText('POINT(' || NEW.entity_lat || ' ' || NEW.entity_lon || ')'), 4326), 900913);
	END IF;

	buffer       := 30;
	NEW.the_geom := NULL;

	IF NEW.entity_level = 'stop' THEN
		primitive := true;
	END IF;

	-- Create polygon members
	IF primitive THEN
		FOR i IN array_lower(NEW.entity_polygon, 1) .. array_upper(NEW.entity_polygon, 1) LOOP
			polygon_geom := create_entity_geom(NEW.entity_polygon[i], primitive, NEW.the_geom_point);
			IF NEW.the_geom IS NOT NULL THEN
				NEW.the_geom := St_Union(NEW.the_geom, polygon_geom);
			ELSE
				NEW.the_geom := polygon_geom;
			END IF;
		END LOOP;
	ELSE
		FOR i IN array_lower(NEW.entity_members, 1) .. array_upper(NEW.entity_members, 1) LOOP
			polygon_geom := create_entity_geom(NEW.entity_members[i], primitive, NEW.the_geom_point);
			FOR geom_rec IN SELECT * FROM ST_Dump(polygon_geom) LOOP
				polygon_geom := geom_rec.geom;
				IF NEW.the_geom IS NOT NULL THEN
					inner_geom   := St_Union(inner_geom, ST_MakePolygon(ST_ExteriorRing(polygon_geom)));
					NEW.the_geom := ST_ConvexHull(St_Collect(NEW.the_geom, ST_Buffer(polygon_geom, buffer)));
				ELSE
					inner_geom   := ST_MakePolygon(ST_ExteriorRing(polygon_geom));
					NEW.the_geom := ST_Buffer(polygon_geom, buffer);
				END IF;
			END LOOP;
		END LOOP;
	END IF;

	-- For non-primitive entities remove the geometries for sub-entities,
	-- since that makes the rendering cleaner.
	IF NOT primitive THEN
		NEW.the_geom = ST_Difference(NEW.the_geom, inner_geom);
	END IF;

	RETURN NEW;
END$$;

/* Create geometries for entity */
CREATE FUNCTION create_entity_geom(mid text, primitive boolean, geom_point geometry) RETURNS geometry
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	geom geometry;
	geom_nodes geometry[];
	rec record;
	rec3 record;
	linemaking text;
	buffer      integer;
	buffer_poly integer;
BEGIN
	geom := NULL;

	IF NOT primitive THEN
		SELECT the_geom INTO geom FROM entity_geom WHERE osm_entity_id = mid;
	END IF;

	buffer      := 10;
	buffer_poly :=  5;

	IF geom IS NULL THEN
		IF position('node_' in mid) THEN
			-- create point
			SELECT lon, lat INTO rec FROM planet_osm_nodes WHERE id = substring(mid from 6)::integer;
			geom := ST_SetSRID(ST_GeomFromText('POINT(' || (rec.lon::float / 100::float)::text || ' ' || (rec.lat::float / 100::float)::text || ')'), 900913);
			geom := ST_Buffer(geom_point, buffer);
		ELSIF position('way_' in mid) THEN
			SELECT way INTO geom FROM planet_osm_polygon WHERE osm_id = substring(mid from 5)::integer;
			IF geom IS NULL THEN
				-- create linestring
				SELECT nodes INTO rec FROM planet_osm_ways WHERE id = substring(mid from 5)::integer;
				--FOR i IN array_lower(rec.nodes, 1) .. array_upper(rec.nodes, 1) LOOP
				--	geom_nodes[i] := create_entity_geom('node_' || rec.nodes[i]::text, true);
				--END LOOP;
				--geom := ST_MakeLine(geom_nodes);

				IF rec IS NOT NULL AND array_length(rec.nodes, 1) > 0 THEN
					FOR i IN array_lower(rec.nodes, 1) .. array_upper(rec.nodes, 1) LOOP
						SELECT lon, lat INTO rec3 FROM planet_osm_nodes WHERE id = rec.nodes[i];
						IF linemaking IS NULL THEN
							linemaking := 'LINESTRING(';
						ELSE
							linemaking := linemaking || ',';
						END IF;
						linemaking := linemaking || (rec3.lon::float / 100::float)::text || ' ' || (rec3.lat::float / 100::float)::text ;
					END LOOP;
					linemaking := linemaking || ')';
					geom := ST_SetSRID(ST_GeomFromText(linemaking), 900913);
					geom := ST_Buffer(geom, buffer);
				END IF;
			ELSE
				geom := ST_Buffer(geom, buffer_poly);
			END IF;
		ELSIF position('relation_' in mid) THEN
			SELECT ST_MakePolygon(ST_ExteriorRing(way)) INTO geom FROM planet_osm_polygon WHERE osm_id = -1 * substring(mid from 10)::integer;
			geom := ST_Buffer(geom, buffer_poly);
		END IF;

		IF geom IS NULL THEN
			geom := ST_Buffer(geom_point, buffer);
		END IF;
	END IF;

	RETURN geom;
END$$;

ALTER TABLE ONLY entity_geom
    ADD CONSTRAINT pk_entity_geom PRIMARY KEY (osm_entity_id);
ALTER TABLE ONLY entity_geom
    ADD CONSTRAINT pk_qgis_is_stupid UNIQUE (qgis_is_stupid);
ALTER TABLE ONLY entity_gtfs_map
    ADD CONSTRAINT pk_entity_gtfs_map PRIMARY KEY (osm_entity_id, gtfs_id);
ALTER TABLE ONLY stops
    ADD CONSTRAINT pk_stops PRIMARY KEY (stop_id);

CREATE INDEX i_stop_geom      ON stops           USING gist  (stop_geom     );
CREATE INDEX i_the_geom       ON entity_geom     USING gist  (the_geom      );
CREATE INDEX i_the_geom_point ON entity_geom     USING gist  (the_geom_point);

CREATE INDEX i_entity_gtfs_E  ON entity_gtfs_map USING btree ((osm_entity_id::text));
CREATE INDEX i_entity_gtfs_G  ON entity_gtfs_map USING btree ((gtfs_id::text)      );

CREATE TRIGGER entity_gtfs_map_delete_trigger
    AFTER DELETE ON entity_geom
    FOR EACH ROW
    EXECUTE PROCEDURE entity_gtfs_map_delete();
CREATE TRIGGER entity_gtfs_map_insert_trigger
    BEFORE INSERT ON entity_geom
    FOR EACH ROW
    EXECUTE PROCEDURE entity_gtfs_map_insert();
CREATE TRIGGER entity_gtfs_map_update_trigger
    BEFORE UPDATE ON entity_geom
    FOR EACH ROW
    EXECUTE PROCEDURE entity_gtfs_map_update();

CREATE TRIGGER stop_geom_trigger
    BEFORE INSERT OR UPDATE ON stops
    FOR EACH ROW
    EXECUTE PROCEDURE stops_update_geom();

CREATE TRIGGER entity_geom_trigger
    BEFORE INSERT OR UPDATE ON entity_geom
    FOR EACH ROW
    EXECUTE PROCEDURE entity_update_geom();

GRANT SELECT ON TABLE entity_geom, entity_gtfs_map, stops, geometry_columns, spatial_ref_sys TO PUBLIC;

COMMIT;
