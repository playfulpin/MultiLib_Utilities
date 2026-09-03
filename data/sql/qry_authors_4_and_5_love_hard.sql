-- +-----------------------------------------------
-- |
-- |  query will select distinct list of authors
-- |  that have at least 1(one) book rated '4' or '5'
-- |  in the specified genre 
-- |
-- +-----------------------------------------------
--
-- HISTORY / PROVENANCE
--
-- This is the ORIGINAL author-list query.  Run against the catalog state
-- before the 2026-09-03 reload, its output was committed as the 6,088-name
-- snapshot data/fixtures/authors_list_from_db.txt and fed the author
-- skeleton / prefix toolchain from 2026-08-13 until 2026-09-03.
--
-- Two properties made it a poor fit for a library-wide author skeleton:
--
--   * Genre-restricted: it only matches books in the single genre whose
--     genrenamerus is 'Порно' (the WHERE subquery), so authors whose
--     4/5-rated books carry any other genre never appeared.
--   * Raw CONCAT output: FirstName/MiddleName were concatenated without
--     trimming, so emitted names carried trailing spaces (snapshot rows
--     looked like 'Ande  ').
--
-- SUPERSEDED on 2026-09-03 by qry_authors_4_and_5_all.sql (all genres,
-- plus TotalCount >= 10 / NormalCount > 6 thresholds), which regenerated
-- the fixture at 13,396 names.  Kept for provenance only; do not reuse
-- for the author list.
SELECT DISTINCT
   --     a_name.authorid    AS Authorid  ,
   --     a_name.LastName    AS LastName  ,
   --     a_name.FirstName   AS FirstName ,
   --     a_name.MiddleName  AS MiddleName,
   --     a_name.FullName    AS fullname  ,
        CONCAT(a_name.LastName, ' ', a_name.FirstName, ' ', a_name.MiddleName) AS CompleteName
   --    a_name.TotalCount  AS TotCount  ,
   --     a_name.NormalCount AS BookCount
FROM
        mlgenrename  gname,
        mlrating     r    ,
        mlgenre      g    ,
        mlbook       b    ,
        mlauthor     a    ,
        mlauthorname a_name
WHERE
        g.genreid          = gname.genreid
AND     g.bookid           = b.bookid
AND     g.bookid           = r.bookid
AND     a.bookid           = b.bookid
AND     a_name.authorid    = a.authorid
-- AND     a_name.TotalCount  >= 10
-- AND     a_name.NormalCount > 6
AND     r.rating IN ('4',
                     '5')
AND     b.lang = 'ru'
AND     g.genreid IN
        (
                SELECT
                        mlgenrename.genreid
                FROM
                        mlgenrename
                WHERE
                        mlgenrename.genrenamerus = "Порно"
                        )
ORDER BY 1;

