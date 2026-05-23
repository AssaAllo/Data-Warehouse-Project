-- ============================================================
--  SAKILA 360 - DATA WAREHOUSE
--  Projet : Analyse de la Performance des Locations
--  Base cible : sakila_dwh
-- ============================================================

-- ==========================
-- ÉTAPE 0 : Création de la base DWH
-- ==========================
CREATE DATABASE IF NOT EXISTS sakila_dwh
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE sakila_dwh;

-- ==========================
-- ÉTAPE 1 : DIMENSIONS
-- ==========================

-- ---- dim_date ----
CREATE TABLE IF NOT EXISTS dim_date (
    date_key        INT          NOT NULL PRIMARY KEY,   -- Format YYYYMMDD
    full_date       DATE         NOT NULL,
    day_of_week     TINYINT      NOT NULL,               -- 1=Lundi ... 7=Dimanche
    day_name        VARCHAR(20)  NOT NULL,
    day_of_month    TINYINT      NOT NULL,
    day_of_year     SMALLINT     NOT NULL,
    week_of_year    TINYINT      NOT NULL,
    month_num       TINYINT      NOT NULL,
    month_name      VARCHAR(20)  NOT NULL,
    quarter         TINYINT      NOT NULL,
    year            SMALLINT     NOT NULL,
    is_weekend      BOOLEAN      NOT NULL DEFAULT FALSE,
    is_holiday      BOOLEAN      NOT NULL DEFAULT FALSE,
    holiday_name    VARCHAR(100) NULL
);

-- ---- dim_film ----
CREATE TABLE IF NOT EXISTS dim_film (
    film_key        INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    film_id         SMALLINT     NOT NULL,               -- clé naturelle
    title           VARCHAR(255) NOT NULL,
    description     TEXT,
    release_year    YEAR,
    language        VARCHAR(50),
    rating          VARCHAR(10),                         -- G, PG, PG-13, R, NC-17
    category        VARCHAR(50),
    rental_duration TINYINT,                             -- durée standard (jours)
    rental_rate     DECIMAL(4,2),
    replacement_cost DECIMAL(5,2),
    -- SCD Type 2
    valid_from      DATE         NOT NULL DEFAULT (CURRENT_DATE),
    valid_to        DATE         NULL,
    is_current      BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---- dim_customer ----
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key    INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id     SMALLINT     NOT NULL,               -- clé naturelle
    first_name      VARCHAR(45)  NOT NULL,
    last_name       VARCHAR(45)  NOT NULL,
    full_name       VARCHAR(91)  GENERATED ALWAYS AS (CONCAT(first_name, ' ', last_name)) STORED,
    email           VARCHAR(50),
    city            VARCHAR(50),
    country         VARCHAR(50),
    segment         VARCHAR(30),                         -- Fidèle / Occasionnel / Inactif
    active          BOOLEAN,
    -- SCD Type 2
    valid_from      DATE         NOT NULL DEFAULT (CURRENT_DATE),
    valid_to        DATE         NULL,
    is_current      BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---- dim_store ----
CREATE TABLE IF NOT EXISTS dim_store (
    store_key       INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    store_id        TINYINT      NOT NULL,
    address         VARCHAR(50),
    district        VARCHAR(20),
    city            VARCHAR(50),
    country         VARCHAR(50),
    postal_code     VARCHAR(10),
    manager_first   VARCHAR(45),
    manager_last    VARCHAR(45),
    manager_full    VARCHAR(91)  GENERATED ALWAYS AS (CONCAT(manager_first, ' ', manager_last)) STORED
);

-- ==========================
-- ÉTAPE 2 : TABLE DE FAITS
-- ==========================

CREATE TABLE IF NOT EXISTS fact_rental (
    rental_key      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    rental_id       INT          NOT NULL,               -- clé naturelle source
    -- Clés étrangères dimensions
    date_key        INT          NOT NULL,
    film_key        INT          NOT NULL,
    customer_key    INT          NOT NULL,
    store_key       INT          NOT NULL,
    -- Mesures
    rental_duration INT          NOT NULL COMMENT 'Durée réelle en jours',
    amount          DECIMAL(5,2) NOT NULL COMMENT 'Montant total payé',
    late_fee        DECIMAL(5,2) NOT NULL DEFAULT 0.00 COMMENT 'Pénalité de retard calculée',
    count_rental    TINYINT      NOT NULL DEFAULT 1,
    -- Dates brutes (pour calcul de retard)
    rental_date     DATETIME     NOT NULL,
    return_date     DATETIME     NULL,
    due_date        DATETIME     NOT NULL COMMENT 'Date de retour prévue',
    days_late       INT          GENERATED ALWAYS AS (
                        CASE
                          WHEN return_date IS NULL THEN NULL
                          WHEN return_date > due_date
                            THEN DATEDIFF(return_date, due_date)
                          ELSE 0
                        END
                    ) STORED,
    is_returned     BOOLEAN      GENERATED ALWAYS AS (return_date IS NOT NULL) STORED,
    -- Contraintes
    CONSTRAINT fk_fr_date     FOREIGN KEY (date_key)     REFERENCES dim_date(date_key),
    CONSTRAINT fk_fr_film     FOREIGN KEY (film_key)     REFERENCES dim_film(film_key),
    CONSTRAINT fk_fr_customer FOREIGN KEY (customer_key) REFERENCES dim_customer(customer_key),
    CONSTRAINT fk_fr_store    FOREIGN KEY (store_key)    REFERENCES dim_store(store_key),
    INDEX idx_fr_date     (date_key),
    INDEX idx_fr_film     (film_key),
    INDEX idx_fr_customer (customer_key),
    INDEX idx_fr_store    (store_key),
    INDEX idx_fr_rental_date (rental_date)
);

-- ==========================
-- ÉTAPE 3 : ETL — PEUPLEMENT
-- ==========================
-- Source : base sakila (schéma normalisé)
-- Cible  : sakila_dwh (schéma en étoile)

-- ---- 3.1 : dim_date (génération automatique 2000-2010) ----
DROP PROCEDURE IF EXISTS sp_load_dim_date;
DELIMITER $$
CREATE PROCEDURE sp_load_dim_date(IN p_start DATE, IN p_end DATE)
BEGIN
    DECLARE v_date DATE DEFAULT p_start;
    WHILE v_date <= p_end DO
        INSERT IGNORE INTO dim_date (
            date_key, full_date,
            day_of_week, day_name, day_of_month, day_of_year, week_of_year,
            month_num, month_name, quarter, year,
            is_weekend, is_holiday, holiday_name
        ) VALUES (
            DATE_FORMAT(v_date, '%Y%m%d'),
            v_date,
            DAYOFWEEK(v_date),
            DAYNAME(v_date),
            DAY(v_date),
            DAYOFYEAR(v_date),
            WEEK(v_date, 1),
            MONTH(v_date),
            MONTHNAME(v_date),
            QUARTER(v_date),
            YEAR(v_date),
            DAYOFWEEK(v_date) IN (1, 7),
            FALSE,
            NULL
        );
        SET v_date = DATE_ADD(v_date, INTERVAL 1 DAY);
    END WHILE;
END $$
DELIMITER ;

CALL sp_load_dim_date('2000-01-01', '2010-12-31');

-- ---- 3.2 : dim_film ----
INSERT INTO sakila_dwh.dim_film (
    film_id, title, description, release_year, language,
    rating, category, rental_duration, rental_rate, replacement_cost,
    valid_from, valid_to, is_current
)
SELECT
    f.film_id,
    f.title,
    f.description,
    f.release_year,
    l.name                        AS language,
    f.rating,
    c.name                        AS category,
    f.rental_duration,
    f.rental_rate,
    f.replacement_cost,
    CURRENT_DATE,
    NULL,
    TRUE
FROM sakila.film f
JOIN sakila.language l         ON f.language_id    = l.language_id
LEFT JOIN sakila.film_category fc ON f.film_id     = fc.film_id
LEFT JOIN sakila.category c    ON fc.category_id   = c.category_id
ON DUPLICATE KEY UPDATE is_current = TRUE;

-- ---- 3.3 : dim_customer (avec segmentation) ----
INSERT INTO sakila_dwh.dim_customer (
    customer_id, first_name, last_name, email,
    city, country, segment, active,
    valid_from, valid_to, is_current
)
SELECT
    cu.customer_id,
    cu.first_name,
    cu.last_name,
    cu.email,
    ci.city,
    co.country,
    -- Segmentation basée sur le nombre de locations
    CASE
        WHEN rental_count.cnt >= 30 THEN 'Fidèle'
        WHEN rental_count.cnt >= 10 THEN 'Régulier'
        WHEN rental_count.cnt >= 1  THEN 'Occasionnel'
        ELSE 'Inactif'
    END                           AS segment,
    cu.active,
    CURRENT_DATE,
    NULL,
    TRUE
FROM sakila.customer cu
JOIN sakila.address a          ON cu.address_id    = a.address_id
JOIN sakila.city ci            ON a.city_id        = ci.city_id
JOIN sakila.country co         ON ci.country_id    = co.country_id
LEFT JOIN (
    SELECT customer_id, COUNT(*) AS cnt
    FROM sakila.rental
    GROUP BY customer_id
) rental_count ON cu.customer_id = rental_count.customer_id;

-- ---- 3.4 : dim_store ----
INSERT INTO sakila_dwh.dim_store (
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
FROM sakila.store s
JOIN sakila.address a          ON s.address_id     = a.address_id
JOIN sakila.city ci            ON a.city_id        = ci.city_id
JOIN sakila.country co         ON ci.country_id    = co.country_id
JOIN sakila.staff sf           ON s.manager_staff_id = sf.staff_id;

-- ---- 3.5 : fact_rental (avec calcul de late_fee) ----
-- Hypothèse de pénalité : 1$ par jour de retard
INSERT INTO sakila_dwh.fact_rental (
    rental_id, date_key, film_key, customer_key, store_key,
    rental_duration, amount, late_fee,
    rental_date, return_date, due_date
)
SELECT
    r.rental_id,
    -- date_key = date de location
    CAST(DATE_FORMAT(r.rental_date, '%Y%m%d') AS UNSIGNED)  AS date_key,
    -- film_key : version actuelle
    df.film_key,
    -- customer_key : version actuelle
    dc.customer_key,
    -- store_key via inventory
    dst.store_key,
    -- durée réelle
    CASE
        WHEN r.return_date IS NOT NULL
            THEN DATEDIFF(r.return_date, r.rental_date)
        ELSE NULL
    END                                                       AS rental_duration,
    -- montant total des paiements pour cette location
    COALESCE(p.total_paid, 0)                                AS amount,
    -- pénalité de retard : max(0, (retour_réel - retour_prévu) * rate/durée_standard)
    CASE
        WHEN r.return_date IS NOT NULL
             AND r.return_date > DATE_ADD(r.rental_date, INTERVAL f.rental_duration DAY)
            THEN ROUND(
                    DATEDIFF(r.return_date, DATE_ADD(r.rental_date, INTERVAL f.rental_duration DAY))
                    * (f.rental_rate / f.rental_duration),
                 2)
        ELSE 0.00
    END                                                       AS late_fee,
    r.rental_date,
    r.return_date,
    DATE_ADD(r.rental_date, INTERVAL f.rental_duration DAY)  AS due_date
FROM sakila.rental r
JOIN sakila.inventory i        ON r.inventory_id   = i.inventory_id
JOIN sakila.film f             ON i.film_id        = f.film_id
-- Dimensions (version courante — SCD Type 2)
JOIN sakila_dwh.dim_film df    ON f.film_id        = df.film_id    AND df.is_current = TRUE
JOIN sakila_dwh.dim_customer dc ON r.customer_id   = dc.customer_id AND dc.is_current = TRUE
JOIN sakila_dwh.dim_store dst  ON i.store_id       = dst.store_id
-- Paiements agrégés par location
LEFT JOIN (
    SELECT rental_id, SUM(amount) AS total_paid
    FROM sakila.payment
    GROUP BY rental_id
) p ON r.rental_id = p.rental_id;

-- ==========================
-- ÉTAPE 4 : REQUÊTES OLAP
-- ==========================

-- ---- Q1 : Évolution mensuelle du CA par catégorie (2005) ----
-- WINDOW FUNCTION : cumul mobile sur 3 mois
SELECT
    dd.year,
    dd.month_num,
    dd.month_name,
    df.category,
    SUM(fr.amount)                                                          AS ca_mensuel,
    SUM(SUM(fr.amount)) OVER (
        PARTITION BY df.category
        ORDER BY dd.year, dd.month_num
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )                                                                       AS ca_mobile_3mois,
    ROUND(
        100 * SUM(fr.amount) /
        SUM(SUM(fr.amount)) OVER (PARTITION BY dd.year, dd.month_num),
     2)                                                                     AS part_marche_pct
FROM sakila_dwh.fact_rental   fr
JOIN sakila_dwh.dim_date      dd ON fr.date_key    = dd.date_key
JOIN sakila_dwh.dim_film      df ON fr.film_key    = df.film_key
WHERE dd.year = 2005
GROUP BY dd.year, dd.month_num, dd.month_name, df.category
ORDER BY dd.month_num, ca_mensuel DESC;

-- ---- Q2 : Top 5 films avec le plus de pénalités par magasin ----
SELECT
    ds.store_id,
    ds.city                                                                 AS ville_magasin,
    df.title                                                                AS titre_film,
    df.category,
    SUM(fr.late_fee)                                                        AS total_penalites,
    COUNT(*)                                                                AS nb_locations_tardives,
    ROUND(AVG(fr.days_late), 1)                                            AS retard_moyen_jours,
    RANK() OVER (
        PARTITION BY ds.store_id
        ORDER BY SUM(fr.late_fee) DESC
    )                                                                       AS rang_par_magasin
FROM sakila_dwh.fact_rental   fr
JOIN sakila_dwh.dim_film      df ON fr.film_key    = df.film_key
JOIN sakila_dwh.dim_store     ds ON fr.store_key   = ds.store_key
WHERE fr.late_fee > 0
GROUP BY ds.store_id, ds.city, df.title, df.category
QUALIFY rang_par_magasin <= 5   -- MySQL 8.0.29+ ; sinon utiliser sous-requête
ORDER BY ds.store_id, rang_par_magasin;

-- Alternative compatible MySQL < 8.0.29 :
SELECT * FROM (
    SELECT
        ds.store_id,
        ds.city                                                             AS ville_magasin,
        df.title                                                            AS titre_film,
        df.category,
        SUM(fr.late_fee)                                                    AS total_penalites,
        COUNT(*)                                                            AS nb_locations_tardives,
        ROUND(AVG(fr.days_late), 1)                                        AS retard_moyen_jours,
        RANK() OVER (
            PARTITION BY ds.store_id
            ORDER BY SUM(fr.late_fee) DESC
        )                                                                   AS rang_par_magasin
    FROM sakila_dwh.fact_rental   fr
    JOIN sakila_dwh.dim_film      df ON fr.film_key  = df.film_key
    JOIN sakila_dwh.dim_store     ds ON fr.store_key = ds.store_key
    WHERE fr.late_fee > 0
    GROUP BY ds.store_id, ds.city, df.title, df.category
) ranked
WHERE rang_par_magasin <= 5
ORDER BY store_id, rang_par_magasin;

-- ---- Q3 : Corrélation pays-client / genre de film ----
SELECT
    dc.country,
    df.category,
    COUNT(*)                                                                AS nb_locations,
    ROUND(
        100.0 * COUNT(*) /
        SUM(COUNT(*)) OVER (PARTITION BY dc.country),
    2)                                                                      AS pct_dans_pays,
    RANK() OVER (
        PARTITION BY dc.country
        ORDER BY COUNT(*) DESC
    )                                                                       AS rang_categorie
FROM sakila_dwh.fact_rental   fr
JOIN sakila_dwh.dim_customer  dc ON fr.customer_key = dc.customer_key
JOIN sakila_dwh.dim_film      df ON fr.film_key     = df.film_key
GROUP BY dc.country, df.category
ORDER BY dc.country, nb_locations DESC;

-- ---- Q4 : Taux d'occupation — films jamais loués au dernier trimestre ----
WITH dernier_trimestre AS (
    SELECT
        MAX(dd.year)    AS annee,
        MAX(dd.quarter) AS trimestre
    FROM sakila_dwh.fact_rental fr
    JOIN sakila_dwh.dim_date dd ON fr.date_key = dd.date_key
),
films_loues AS (
    SELECT DISTINCT fr.film_key
    FROM sakila_dwh.fact_rental fr
    JOIN sakila_dwh.dim_date    dd ON fr.date_key = dd.date_key
    JOIN dernier_trimestre dt
    WHERE dd.year = dt.annee AND dd.quarter = dt.trimestre
),
inventaire_total AS (
    SELECT COUNT(DISTINCT film_key) AS total_films
    FROM sakila_dwh.dim_film
    WHERE is_current = TRUE
)
SELECT
    it.total_films,
    COUNT(DISTINCT fl.film_key)                                             AS films_loues_trim,
    it.total_films - COUNT(DISTINCT fl.film_key)                           AS films_non_loues,
    ROUND(
        100.0 * (it.total_films - COUNT(DISTINCT fl.film_key)) / it.total_films,
    2)                                                                      AS pct_non_loues,
    ROUND(
        100.0 * COUNT(DISTINCT fl.film_key) / it.total_films,
    2)                                                                      AS taux_occupation_pct
FROM inventaire_total it
LEFT JOIN films_loues fl ON TRUE;

-- ==========================
-- ÉTAPE 5 : VUES ANALYTIQUES
-- ==========================

CREATE OR REPLACE VIEW v_ca_mensuel_categorie AS
SELECT
    dd.year, dd.month_num, dd.month_name, dd.quarter,
    df.category,
    COUNT(fr.rental_key)     AS nb_locations,
    SUM(fr.amount)           AS chiffre_affaires,
    SUM(fr.late_fee)         AS total_penalites,
    AVG(fr.rental_duration)  AS duree_moyenne
FROM sakila_dwh.fact_rental fr
JOIN sakila_dwh.dim_date    dd ON fr.date_key    = dd.date_key
JOIN sakila_dwh.dim_film    df ON fr.film_key    = df.film_key
GROUP BY dd.year, dd.month_num, dd.month_name, dd.quarter, df.category;

CREATE OR REPLACE VIEW v_performance_client AS
SELECT
    dc.customer_key, dc.full_name, dc.country, dc.city, dc.segment,
    COUNT(fr.rental_key)     AS nb_locations,
    SUM(fr.amount)           AS ca_total,
    SUM(fr.late_fee)         AS penalites_total,
    AVG(fr.rental_duration)  AS duree_moy_location
FROM sakila_dwh.fact_rental  fr
JOIN sakila_dwh.dim_customer dc ON fr.customer_key = dc.customer_key
GROUP BY dc.customer_key, dc.full_name, dc.country, dc.city, dc.segment;

-- Fin du script
SELECT 'ETL Sakila DWH terminé avec succès !' AS statut;
