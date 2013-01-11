MÁV-START Zrt GTFS menetrendek
==============================

A hivatalos menetrend az alábbi címen található:
<http://elvira.mav-start.hu>

A menetrend adatok az ELVIRA-ból származnak. Az állomás/megálló adatok az
[OpenStreetMap-ből](http://www.openstreetmap.org) származnak.

Az OpenStreetMap-ben található vasútvonalak segítségével valamennyi vonathoz
készül egy nyomvonal mely a síneket követi. Ahol vágányok/peronok is vannak
az OpenStreetMap-ben (és én ezt észreveszem) ott vágányszíntű indulásokat 
is ismer a GTFS adathalmaz (Ez jelenleg Kelenföld + néhány környékben levő
vasútállomás/megállóhely).

A kerékpárok szállíthatósága (`trips.txt:trip_bicycles_allowed`), valamint a
tolószék használhatósága (`trips.txt:wheelchair_accessible`) is fel van tüntetve.

Megjegyzések
------------

### Zónák

* BKSZ,MAV          - BKSZ bérlettel igénybe vehető
* BKSZ_DISCOUNT,MAV - BKSZ kedvezmény igénybe vehető
* MAV               - Minden extra nélküli megálló

### stops.txt:stop_code

A feldolgozás idejében érvényes ELVIRA megálló azonosítót tartalmazza.

