-- ================================================================
--  SAKILA 360 — DATA WAREHOUSE (PostgreSQL)
--  Projet : Analyse de la Performance des Locations
--  Cible  : base sakila_dwh  |  Source : base sakila (schéma public)
--  SGBD   : PostgreSQL 13+
--
--  UTILISATION :
--    1. Créer la base cible  →  CREATE DATABASE sakila_dwh;
--    2. Se connecter         →  \c sakila_dwh
--    3. Exécuter ce script   →  \i sakila_dwh_postgresql.sql
--
--  PRÉREQUIS :
--    - Extension postgres_fdw OU les deux bases sur le même cluster
--      (sinon adapter les INSERT avec dblink / FDW)
--    - Base sakila peuplée (dump disponible sur dev.mysql.com/doc/sakila)
-- ================================================================

-- ---------------------------------------------------------------
-- 0. EXTENSIONS ET SCHÉMA
-- ---------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- recherche textuelle (optionnel)
CREATE EXTENSION IF NOT EXISTS dblink;      -- accès cross-base si nécessaire

-- Schéma dédié au DWH (bonne pratique : isoler du schéma public)
CREATE SCHEMA IF NOT EXISTS dwh;
SET search_path = dwh, public;

-- ---------------------------------------------------------------
-- 1. NETTOYAGE (idempotent — relance possible sans erreur)
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS dwh.fact_rental    CASCADE;
DROP TABLE IF EXISTS dwh.dim_date       CASCADE;
DROP TABLE IF EXISTS dwh.dim_film       CASCADE;
DROP TABLE IF EXISTS dwh.dim_customer   CASCADE;
DROP TABLE IF EXISTS dwh.dim_store      CASCADE;

DROP FUNCTION IF EXISTS dwh.fn_load_dim_date(DATE, DATE);
DROP FUNCTION IF EXISTS dwh.fn_customer_segment(INT);
DROP PROCEDURE IF EXISTS dwh.sp_load_all();

-- ---------------------------------------------------------------
-- 2. DIMENSIONS
-- ---------------------------------------------------------------

-- -------- dim_date --------
-- Peuplée indépendamment des données source via generate_series.
-- Couvre toute plage de dates ; pas de clé étrangère vers sakila.
CREATE TABLE dwh.dim_date (
    date_key        INTEGER         NOT NULL,   -- YYYYMMDD  ex: 20050715
    full_date       DATE            NOT NULL,
    day_of_week     SMALLINT        NOT NULL,   -- 1=Lundi … 7=Dimanche (ISO)
    day_name        VARCHAR(20)     NOT NULL,   -- 'Monday', 'Tuesday'…
    day_of_month    SMALLINT        NOT NULL,
    day_of_year     SMALLINT        NOT NULL,
    week_of_year    SMALLINT        NOT NULL,   -- ISO 8601
    month_num       SMALLINT        NOT NULL,
    month_name      VARCHAR(20)     NOT NULL,
    quarter         SMALLINT        NOT NULL,
    year            SMALLINT        NOT NULL,
    is_weekend      BOOLEAN         NOT NULL DEFAULT FALSE,
    is_holiday      BOOLEAN         NOT NULL DEFAULT FALSE,
    holiday_name    VARCHAR(100),
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key)
);

COMMENT ON TABLE  dwh.dim_date              IS 'Dimension temporelle — générée par fn_load_dim_date()';
COMMENT ON COLUMN dwh.dim_date.date_key     IS 'Clé surrogate format YYYYMMDD';
COMMENT ON COLUMN dwh.dim_date.day_of_week  IS '1=Lundi … 7=Dimanche (norme ISO)';

-- -------- dim_film --------
-- SCD Type 2 : valid_from / valid_to / is_current
CREATE TABLE dwh.dim_film (
    film_key            SERIAL          PRIMARY KEY,
    film_id             SMALLINT        NOT NULL,           -- clé naturelle source
    title               VARCHAR(255)    NOT NULL,
    description         TEXT,
    release_year        SMALLINT,
    language            VARCHAR(50),
    rating              VARCHAR(10),                        -- G PG PG-13 R NC-17
    category            VARCHAR(50),
    rental_duration     SMALLINT,                           -- durée standard (jours)
    rental_rate         NUMERIC(4,2),
    replacement_cost    NUMERIC(5,2),
    -- SCD Type 2
    valid_from          DATE            NOT NULL DEFAULT CURRENT_DATE,
    valid_to            DATE,
    is_current          BOOLEAN         NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_dim_film_current UNIQUE (film_id, valid_from)
);

CREATE INDEX idx_dim_film_id      ON dwh.dim_film (film_id);
CREATE INDEX idx_dim_film_current ON dwh.dim_film (is_current) WHERE is_current;

COMMENT ON TABLE dwh.dim_film IS 'Dimension film — SCD Type 2 (historique des changements)';

-- -------- dim_customer --------
-- SCD Type 2 + segmentation calculée à l'ETL
CREATE TABLE dwh.dim_customer (
    customer_key    SERIAL          PRIMARY KEY,
    customer_id     SMALLINT        NOT NULL,               -- clé naturelle source
    first_name      VARCHAR(45)     NOT NULL,
    last_name       VARCHAR(45)     NOT NULL,
    full_name       VARCHAR(91)     GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    email           VARCHAR(50),
    city            VARCHAR(50),
    country         VARCHAR(50),
    segment         VARCHAR(20),    -- Fidèle | Régulier | Occasionnel | Inactif
    active          BOOLEAN,
    -- SCD Type 2
    valid_from      DATE            NOT NULL DEFAULT CURRENT_DATE,
    valid_to        DATE,
    is_current      BOOLEAN         NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_dim_customer_current UNIQUE (customer_id, valid_from)
);

CREATE INDEX idx_dim_cust_id      ON dwh.dim_customer (customer_id);
CREATE INDEX idx_dim_cust_current ON dwh.dim_customer (is_current) WHERE is_current;
CREATE INDEX idx_dim_cust_country ON dwh.dim_customer (country);

-- -------- dim_store --------
CREATE TABLE dwh.dim_store (
    store_key       SERIAL          PRIMARY KEY,
    store_id        SMALLINT        NOT NULL UNIQUE,
    address         VARCHAR(50),
    district        VARCHAR(20),
    city            VARCHAR(50),
    country         VARCHAR(50),
    postal_code     VARCHAR(10),
    manager_first   VARCHAR(45),
    manager_last    VARCHAR(45),
    manager_full    VARCHAR(91)     GENERATED ALWAYS AS (manager_first || ' ' || manager_last) STORED
);

-- ---------------------------------------------------------------
-- 3. TABLE DE FAITS — fact_rental
-- ---------------------------------------------------------------
CREATE TABLE dwh.fact_rental (
    rental_key          BIGSERIAL       PRIMARY KEY,
    rental_id           INTEGER         NOT NULL,           -- clé naturelle source

    -- Clés étrangères vers les dimensions
    date_key            INTEGER         NOT NULL,
    film_key            INTEGER         NOT NULL,
    customer_key        INTEGER         NOT NULL,
    store_key           INTEGER         NOT NULL,

    -- Mesures
    rental_duration     INTEGER,                            -- durée réelle (jours), NULL si non rendu
    amount              NUMERIC(5,2)    NOT NULL DEFAULT 0, -- total paiements
    late_fee            NUMERIC(5,2)    NOT NULL DEFAULT 0, -- pénalité calculée
    count_rental        SMALLINT        NOT NULL DEFAULT 1, -- toujours 1 ; utile pour SUM()

    -- Dates détaillées (évite les jointures pour les calculs de retard)
    rental_date         TIMESTAMP       NOT NULL,
    return_date         TIMESTAMP,
    due_date            TIMESTAMP       NOT NULL,           -- rental_date + durée_standard

    -- Colonnes calculées (GENERATED — PostgreSQL 12+)
    days_late           INTEGER         GENERATED ALWAYS AS (
                            CASE
                                WHEN return_date IS NOT NULL AND return_date > due_date
                                    THEN EXTRACT(DAY FROM return_date - due_date)::INTEGER
                                WHEN return_date IS NOT NULL
                                    THEN 0
                                ELSE NULL
                            END
                        ) STORED,
    is_returned         BOOLEAN         GENERATED ALWAYS AS (return_date IS NOT NULL) STORED,

    -- Contraintes
    CONSTRAINT fk_fr_date     FOREIGN KEY (date_key)     REFERENCES dwh.dim_date(date_key),
    CONSTRAINT fk_fr_film     FOREIGN KEY (film_key)     REFERENCES dwh.dim_film(film_key),
    CONSTRAINT fk_fr_customer FOREIGN KEY (customer_key) REFERENCES dwh.dim_customer(customer_key),
    CONSTRAINT fk_fr_store    FOREIGN KEY (store_key)    REFERENCES dwh.dim_store(store_key),
    CONSTRAINT uq_rental_id   UNIQUE (rental_id)
);

-- Index couvrants pour les requêtes OLAP les plus fréquentes
CREATE INDEX idx_fr_date        ON dwh.fact_rental (date_key);
CREATE INDEX idx_fr_film        ON dwh.fact_rental (film_key);
CREATE INDEX idx_fr_customer    ON dwh.fact_rental (customer_key);
CREATE INDEX idx_fr_store       ON dwh.fact_rental (store_key);
CREATE INDEX idx_fr_rental_date ON dwh.fact_rental (rental_date);
CREATE INDEX idx_fr_late_fee    ON dwh.fact_rental (late_fee) WHERE late_fee > 0;
CREATE INDEX idx_fr_is_returned ON dwh.fact_rental (is_returned);

COMMENT ON TABLE  dwh.fact_rental                IS 'Table de faits — grain = 1 ligne par location';
COMMENT ON COLUMN dwh.fact_rental.late_fee       IS 'Pénalité calculée : jours_retard × (rental_rate / rental_duration)';
COMMENT ON COLUMN dwh.fact_rental.days_late      IS 'Colonne générée : nb jours de retard (NULL si non rendu)';
COMMENT ON COLUMN dwh.fact_rental.count_rental   IS 'Compteur fixe = 1 ; permet SUM sans COUNT DISTINCT';

-- ---------------------------------------------------------------
-- 4. ETL — FONCTIONS ET PROCÉDURE DE CHARGEMENT
-- ---------------------------------------------------------------

-- -------- 4.1 Segmentation client --------
CREATE OR REPLACE FUNCTION dwh.fn_customer_segment(p_nb_locations INTEGER)
RETURNS VARCHAR(20)
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN CASE
        WHEN p_nb_locations >= 30 THEN 'Fidèle'
        WHEN p_nb_locations >= 10 THEN 'Régulier'
        WHEN p_nb_locations >= 1  THEN 'Occasionnel'
        ELSE 'Inactif'
    END;
END;
$$;

-- -------- 4.2 Chargement de dim_date --------
-- Génère toutes les dates entre p_start et p_end via generate_series.
-- Appel : SELECT dwh.fn_load_dim_date('2000-01-01', '2010-12-31');
CREATE OR REPLACE FUNCTION dwh.fn_load_dim_date(
    p_start DATE,
    p_end   DATE
)
RETURNS INTEGER           -- nombre de lignes insérées
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    INSERT INTO dwh.dim_date (
        date_key, full_date,
        day_of_week, day_name,
        day_of_month, day_of_year, week_of_year,
        month_num, month_name,
        quarter, year,
        is_weekend
    )
    SELECT
        TO_CHAR(d, 'YYYYMMDD')::INTEGER     AS date_key,
        d                                   AS full_date,
        -- ISO : 1=Lundi … 7=Dimanche
        EXTRACT(ISODOW FROM d)::SMALLINT    AS day_of_week,
        TO_CHAR(d, 'Day')                   AS day_name,
        EXTRACT(DAY   FROM d)::SMALLINT     AS day_of_month,
        EXTRACT(DOY   FROM d)::SMALLINT     AS day_of_year,
        EXTRACT(WEEK  FROM d)::SMALLINT     AS week_of_year,
        EXTRACT(MONTH FROM d)::SMALLINT     AS month_num,
        TO_CHAR(d, 'Month')                 AS month_name,
        EXTRACT(QUARTER FROM d)::SMALLINT   AS quarter,
        EXTRACT(YEAR  FROM d)::SMALLINT     AS year,
        EXTRACT(ISODOW FROM d) IN (6,7)     AS is_weekend
    FROM generate_series(p_start, p_end, INTERVAL '1 day') AS t(d)
    ON CONFLICT (date_key) DO NOTHING;   -- idempotent

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE 'dim_date : % lignes insérées (% → %)', v_count, p_start, p_end;
    RETURN v_count;
END;
$$;

-- -------- 4.3 Procédure principale de chargement --------
-- Charge les 4 dimensions puis la table de faits dans l'ordre correct.
-- La source est le schéma "public" de la base sakila (même cluster).
-- Si sakila est sur un autre serveur, remplacer les FROM sakila.public.*
-- par des foreign tables (postgres_fdw).
CREATE OR REPLACE PROCEDURE dwh.sp_load_all()
LANGUAGE plpgsql
AS $$
DECLARE
    v_start TIMESTAMP := clock_timestamp();
BEGIN
    RAISE NOTICE '==============================';
    RAISE NOTICE 'ETL Sakila DWH — début : %', v_start;
    RAISE NOTICE '==============================';

    -- ---- dim_date ----
    PERFORM dwh.fn_load_dim_date('2000-01-01', '2010-12-31');

    -- ---- dim_store ----
    INSERT INTO dwh.dim_store (
        store_id, address, district, city, country, postal_code,
        manager_first, manager_last
    )
    SELECT
        s.store_id,
        a.address,
        a.district,
        ci.city,
        co.country,
        a.postal_code,
        sf.first_name,
        sf.last_name
    FROM public.store       s
    JOIN public.address     a   ON s.address_id       = a.address_id
    JOIN public.city        ci  ON a.city_id           = ci.city_id
    JOIN public.country     co  ON ci.country_id       = co.country_id
    JOIN public.staff       sf  ON s.manager_staff_id  = sf.staff_id
    ON CONFLICT (store_id) DO UPDATE
        SET address       = EXCLUDED.address,
            manager_first = EXCLUDED.manager_first,
            manager_last  = EXCLUDED.manager_last;

    RAISE NOTICE 'dim_store chargée';

    -- ---- dim_film ----
    -- Insère la version courante ; gère SCD Type 2 (ferme ancienne version si changement)
    -- Étape 1 : fermer les versions dont rating ou category a changé
    UPDATE dwh.dim_film df
    SET    valid_to   = CURRENT_DATE - 1,
           is_current = FALSE
    FROM   public.film            f
    JOIN   public.language        l   ON f.language_id  = l.language_id
    LEFT JOIN public.film_category fc ON f.film_id      = fc.film_id
    LEFT JOIN public.category      c  ON fc.category_id = c.category_id
    WHERE  df.film_id    = f.film_id
    AND    df.is_current = TRUE
    AND    (df.rating   IS DISTINCT FROM f.rating::VARCHAR
         OR df.category IS DISTINCT FROM c.name);

    -- Étape 2 : insérer les nouvelles versions + films jamais vus
    INSERT INTO dwh.dim_film (
        film_id, title, description, release_year, language,
        rating, category, rental_duration, rental_rate, replacement_cost
    )
    SELECT
        f.film_id,
        f.title,
        f.description,
        f.release_year::SMALLINT,
        l.name                              AS language,
        f.rating::VARCHAR                   AS rating,
        c.name                              AS category,
        f.rental_duration::SMALLINT,
        f.rental_rate,
        f.replacement_cost
    FROM   public.film            f
    JOIN   public.language        l   ON f.language_id  = l.language_id
    LEFT JOIN public.film_category fc ON f.film_id      = fc.film_id
    LEFT JOIN public.category      c  ON fc.category_id = c.category_id
    -- N'insérer que si pas déjà une version courante identique
    WHERE NOT EXISTS (
        SELECT 1 FROM dwh.dim_film df2
        WHERE  df2.film_id    = f.film_id
        AND    df2.is_current = TRUE
    )
    ON CONFLICT (film_id, valid_from) DO NOTHING;

    RAISE NOTICE 'dim_film chargée (SCD Type 2)';

    -- ---- dim_customer ----
    -- Même logique SCD Type 2 : fermer si ville/pays a changé
    UPDATE dwh.dim_customer dc
    SET    valid_to   = CURRENT_DATE - 1,
           is_current = FALSE
    FROM   public.customer   cu
    JOIN   public.address     a   ON cu.address_id  = a.address_id
    JOIN   public.city        ci  ON a.city_id       = ci.city_id
    JOIN   public.country     co  ON ci.country_id   = co.country_id
    WHERE  dc.customer_id  = cu.customer_id
    AND    dc.is_current   = TRUE
    AND    (dc.city    IS DISTINCT FROM ci.city
         OR dc.country IS DISTINCT FROM co.country);

    INSERT INTO dwh.dim_customer (
        customer_id, first_name, last_name, email,
        city, country, segment, active
    )
    SELECT
        cu.customer_id,
        cu.first_name,
        cu.last_name,
        cu.email,
        ci.city,
        co.country,
        dwh.fn_customer_segment(COALESCE(rc.cnt, 0)) AS segment,
        cu.active
    FROM   public.customer   cu
    JOIN   public.address     a   ON cu.address_id  = a.address_id
    JOIN   public.city        ci  ON a.city_id       = ci.city_id
    JOIN   public.country     co  ON ci.country_id   = co.country_id
    LEFT JOIN (
        SELECT customer_id, COUNT(*)::INTEGER AS cnt
        FROM   public.rental
        GROUP  BY customer_id
    ) rc ON cu.customer_id = rc.customer_id
    WHERE NOT EXISTS (
        SELECT 1 FROM dwh.dim_customer dc2
        WHERE  dc2.customer_id = cu.customer_id
        AND    dc2.is_current  = TRUE
    )
    ON CONFLICT (customer_id, valid_from) DO NOTHING;

    RAISE NOTICE 'dim_customer chargée (SCD Type 2 + segmentation)';

    -- ---- fact_rental ----
    INSERT INTO dwh.fact_rental (
        rental_id,
        date_key, film_key, customer_key, store_key,
        rental_duration, amount, late_fee,
        rental_date, return_date, due_date
    )
    SELECT
        r.rental_id,

        -- date_key : format YYYYMMDD de la date de location
        TO_CHAR(r.rental_date, 'YYYYMMDD')::INTEGER                     AS date_key,

        -- film_key : version courante dans la dimension
        df.film_key,

        -- customer_key : version courante
        dc.customer_key,

        -- store_key via l'inventaire
        dst.store_key,

        -- durée réelle en jours (NULL si le film n'est pas encore rendu)
        CASE
            WHEN r.return_date IS NOT NULL
                THEN EXTRACT(DAY FROM r.return_date - r.rental_date)::INTEGER
            ELSE NULL
        END                                                              AS rental_duration,

        -- montant total des paiements pour cette location
        COALESCE(p.total_paid, 0)                                        AS amount,

        -- pénalité de retard :
        --   late_fee = jours_retard × (rental_rate / rental_duration_standard)
        --   Proratisé pour refléter le coût journalier réel de chaque film
        CASE
            WHEN r.return_date IS NOT NULL
             AND r.return_date > (r.rental_date + f.rental_duration * INTERVAL '1 day')
                THEN ROUND(
                    EXTRACT(DAY FROM
                        r.return_date -
                        (r.rental_date + f.rental_duration * INTERVAL '1 day')
                    ) * (f.rental_rate / NULLIF(f.rental_duration, 0)),
                2)
            ELSE 0.00
        END                                                              AS late_fee,

        r.rental_date,
        r.return_date,
        r.rental_date + f.rental_duration * INTERVAL '1 day'            AS due_date

    FROM   public.rental        r
    JOIN   public.inventory     i   ON r.inventory_id  = i.inventory_id
    JOIN   public.film          f   ON i.film_id        = f.film_id

    -- Jointure vers les dimensions (version courante — SCD Type 2)
    JOIN   dwh.dim_film         df  ON f.film_id        = df.film_id
                                   AND df.is_current    = TRUE
    JOIN   dwh.dim_customer     dc  ON r.customer_id    = dc.customer_id
                                   AND dc.is_current    = TRUE
    JOIN   dwh.dim_store        dst ON i.store_id       = dst.store_id

    -- Paiements agrégés par location (une location peut avoir plusieurs paiements)
    LEFT JOIN (
        SELECT rental_id, SUM(amount) AS total_paid
        FROM   public.payment
        GROUP  BY rental_id
    ) p ON r.rental_id = p.rental_id

    -- Évite les doublons lors d'une re-exécution
    WHERE NOT EXISTS (
        SELECT 1 FROM dwh.fact_rental fr2
        WHERE  fr2.rental_id = r.rental_id
    );

    RAISE NOTICE 'fact_rental chargée';
    RAISE NOTICE '==============================';
    RAISE NOTICE 'ETL terminé en % s',
        ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start)::NUMERIC, 2);
    RAISE NOTICE '==============================';

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ETL échoué : % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ---------------------------------------------------------------
-- 5. VUES ANALYTIQUES (OLAP)
-- ---------------------------------------------------------------

-- ---- Vue 1 : CA mensuel par catégorie ----
CREATE OR REPLACE VIEW dwh.v_ca_mensuel_categorie AS
SELECT
    dd.year,
    dd.quarter,
    dd.month_num,
    dd.month_name,
    df.category,
    COUNT(fr.rental_key)                AS nb_locations,
    SUM(fr.amount)                      AS chiffre_affaires,
    SUM(fr.late_fee)                    AS total_penalites,
    AVG(fr.rental_duration)             AS duree_moyenne_jours,
    -- Part de marché mensuelle de la catégorie
    ROUND(
        100.0 * SUM(fr.amount)
        / NULLIF(SUM(SUM(fr.amount)) OVER (
            PARTITION BY dd.year, dd.month_num
        ), 0),
    2)                                  AS part_marche_pct,
    -- CA mobile sur 3 mois
    ROUND(
        SUM(SUM(fr.amount)) OVER (
            PARTITION BY df.category
            ORDER BY dd.year, dd.month_num
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
    2)                                  AS ca_mobile_3mois
FROM   dwh.fact_rental   fr
JOIN   dwh.dim_date      dd  ON fr.date_key  = dd.date_key
JOIN   dwh.dim_film      df  ON fr.film_key  = df.film_key
GROUP  BY dd.year, dd.quarter, dd.month_num, dd.month_name, df.category;

-- ---- Vue 2 : Performance client ----
CREATE OR REPLACE VIEW dwh.v_performance_client AS
SELECT
    dc.customer_key,
    dc.full_name,
    dc.country,
    dc.city,
    dc.segment,
    COUNT(fr.rental_key)                AS nb_locations,
    SUM(fr.amount)                      AS ca_total,
    SUM(fr.late_fee)                    AS penalites_total,
    ROUND(AVG(fr.rental_duration), 1)   AS duree_moy_location,
    -- Rang dans le pays
    RANK() OVER (
        PARTITION BY dc.country
        ORDER BY SUM(fr.amount) DESC
    )                                   AS rang_dans_pays
FROM   dwh.fact_rental  fr
JOIN   dwh.dim_customer dc  ON fr.customer_key = dc.customer_key
GROUP  BY dc.customer_key, dc.full_name, dc.country, dc.city, dc.segment;

-- ---- Vue 3 : Taux d'occupation inventaire ----
CREATE OR REPLACE VIEW dwh.v_occupation_inventaire AS
WITH dernier_trimestre AS (
    SELECT
        MAX(dd.year)    AS annee,
        MAX(dd.quarter) AS trimestre
    FROM   dwh.fact_rental fr
    JOIN   dwh.dim_date    dd ON fr.date_key = dd.date_key
),
films_loues_trim AS (
    SELECT DISTINCT fr.film_key
    FROM   dwh.fact_rental fr
    JOIN   dwh.dim_date    dd ON fr.date_key  = dd.date_key
    CROSS  JOIN dernier_trimestre dt
    WHERE  dd.year    = dt.annee
    AND    dd.quarter = dt.trimestre
)
SELECT
    (SELECT COUNT(*) FROM dwh.dim_film  WHERE is_current)    AS total_films,
    COUNT(DISTINCT fl.film_key)                              AS films_loues,
    (SELECT COUNT(*) FROM dwh.dim_film  WHERE is_current)
        - COUNT(DISTINCT fl.film_key)                        AS films_dormants,
    ROUND(
        100.0 * COUNT(DISTINCT fl.film_key)
        / NULLIF((SELECT COUNT(*) FROM dwh.dim_film WHERE is_current), 0),
    2)                                                       AS taux_occupation_pct,
    ROUND(
        100.0 * ((SELECT COUNT(*) FROM dwh.dim_film WHERE is_current)
                  - COUNT(DISTINCT fl.film_key))
        / NULLIF((SELECT COUNT(*) FROM dwh.dim_film WHERE is_current), 0),
    2)                                                       AS taux_dormance_pct
FROM films_loues_trim fl;

-- ---------------------------------------------------------------
-- 6. REQUÊTES OLAP (les 4 questions du projet)
-- ---------------------------------------------------------------

-- ============================================================
-- Q1 — Évolution mensuelle du CA par catégorie (2005)
-- ============================================================
-- Utilise la vue v_ca_mensuel_categorie déjà construite avec
-- window functions (part de marché + CA mobile 3 mois).
-- ============================================================

SELECT
    year,
    month_num,
    month_name,
    category,
    nb_locations,
    ROUND(chiffre_affaires, 2)   AS ca_mensuel,
    ROUND(ca_mobile_3mois, 2)    AS ca_mobile_3mois,
    part_marche_pct
FROM   dwh.v_ca_mensuel_categorie
WHERE  year = 2005
ORDER  BY month_num, ca_mensuel DESC;


-- ============================================================
-- Q2 — Top 5 films avec le plus de pénalités par magasin
--      (RANK() OVER PARTITION BY store)
-- ============================================================

SELECT
    store_id,
    ville_magasin,
    titre_film,
    category,
    ROUND(total_penalites, 2)   AS total_penalites,
    nb_locations_tardives,
    ROUND(retard_moyen_jours,1) AS retard_moyen_jours,
    rang_par_magasin
FROM (
    SELECT
        ds.store_id,
        ds.city                                     AS ville_magasin,
        df.title                                    AS titre_film,
        df.category,
        SUM(fr.late_fee)                            AS total_penalites,
        COUNT(*)                                    AS nb_locations_tardives,
        AVG(fr.days_late)                           AS retard_moyen_jours,
        RANK() OVER (
            PARTITION BY ds.store_id
            ORDER BY SUM(fr.late_fee) DESC
        )                                           AS rang_par_magasin
    FROM   dwh.fact_rental  fr
    JOIN   dwh.dim_film     df  ON fr.film_key  = df.film_key
    JOIN   dwh.dim_store    ds  ON fr.store_key = ds.store_key
    WHERE  fr.late_fee > 0
    GROUP  BY ds.store_id, ds.city, df.title, df.category
) ranked
WHERE  rang_par_magasin <= 5
ORDER  BY store_id, rang_par_magasin;


-- ============================================================
-- Q3 — Corrélation pays-client / genre de film
--      (part du genre dans les locations du pays)
-- ============================================================

SELECT
    dc.country,
    df.category,
    COUNT(*)                                           AS nb_locations,
    ROUND(
        100.0 * COUNT(*)
        / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY dc.country), 0),
    2)                                                 AS pct_dans_pays,
    RANK() OVER (
        PARTITION BY dc.country
        ORDER BY COUNT(*) DESC
    )                                                  AS rang_categorie
FROM   dwh.fact_rental  fr
JOIN   dwh.dim_customer dc  ON fr.customer_key = dc.customer_key
JOIN   dwh.dim_film     df  ON fr.film_key     = df.film_key
GROUP  BY dc.country, df.category
ORDER  BY dc.country, nb_locations DESC;


-- ============================================================
-- Q4 — Taux d'occupation du dernier trimestre
--      (films jamais loués vs inventaire total)
-- ============================================================

SELECT * FROM dwh.v_occupation_inventaire;

-- Détail par catégorie :
WITH dernier_trimestre AS (
    SELECT MAX(year) AS annee, MAX(quarter) AS trimestre
    FROM   dwh.dim_date
    WHERE  date_key IN (SELECT DISTINCT date_key FROM dwh.fact_rental)
),
films_loues AS (
    SELECT DISTINCT df.film_key, df.category
    FROM   dwh.fact_rental fr
    JOIN   dwh.dim_date    dd ON fr.date_key = dd.date_key
    JOIN   dwh.dim_film    df ON fr.film_key = df.film_key
    CROSS  JOIN dernier_trimestre dt
    WHERE  dd.year = dt.annee AND dd.quarter = dt.trimestre
)
SELECT
    df.category,
    COUNT(DISTINCT df.film_key)                     AS total_films_cat,
    COUNT(DISTINCT fl.film_key)                     AS films_loues_cat,
    COUNT(DISTINCT df.film_key)
        - COUNT(DISTINCT fl.film_key)               AS films_dormants_cat,
    ROUND(
        100.0 * (COUNT(DISTINCT df.film_key) - COUNT(DISTINCT fl.film_key))
        / NULLIF(COUNT(DISTINCT df.film_key), 0),
    1)                                              AS pct_dormance
FROM   dwh.dim_film df
LEFT JOIN films_loues fl ON df.film_key = fl.film_key
WHERE  df.is_current
GROUP  BY df.category
ORDER  BY pct_dormance DESC;


-- ---------------------------------------------------------------
-- 7. EXÉCUTION DE L'ETL
-- ---------------------------------------------------------------
-- Décommenter pour lancer le chargement complet :
-- CALL dwh.sp_load_all();

-- Vérification rapide post-ETL :

SELECT
    'dim_date'     AS table_name, COUNT(*) AS nb_lignes FROM dwh.dim_date     UNION ALL
SELECT 'dim_film',                          COUNT(*)    FROM dwh.dim_film     UNION ALL
SELECT 'dim_customer',                      COUNT(*)    FROM dwh.dim_customer UNION ALL
SELECT 'dim_store',                         COUNT(*)    FROM dwh.dim_store    UNION ALL
SELECT 'fact_rental',                       COUNT(*)    FROM dwh.fact_rental
ORDER  BY table_name;


-- ---------------------------------------------------------------
-- FIN DU SCRIPT
-- ---------------------------------------------------------------
DO $$ BEGIN
    RAISE NOTICE '✔  Script sakila_dwh_postgresql.sql chargé avec succès.';
    RAISE NOTICE '   → Lancer l''ETL : CALL dwh.sp_load_all();';
END $$;
