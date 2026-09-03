-- +-----------------------------------------------
-- |
-- |  The query will select a distinct list of authors
-- |  that have at least 1 (one) book rated '4' or '5'
-- |  and the number of the author's books is greater than 6.
-- |
-- +-----------------------------------------------

SELECT DISTINCT --     a_name.authorid    AS Authorid  ,
 --     a_name.LastName    AS LastName  ,
 --     a_name.FirstName   AS FirstName ,
 --     a_name.MiddleName  AS MiddleName,
 --     a_name.FullName    AS fullname  ,
 CONCAT(a_name.LastName, ' ', a_name.FirstName, ' ', a_name.MiddleName) AS CompleteName --    a_name.TotalCount  AS TotCount  ,
 --     a_name.NormalCount AS BookCount
FROM mlgenrename gname,
     mlrating r,
     mlgenre g,
     mlbook b,
     mlauthor a,
     mlauthorname a_name
WHERE g.genreid = gname.genreid
  AND g.bookid = b.bookid
  AND g.bookid = r.bookid
  AND a.bookid = b.bookid
  AND a_name.authorid = a.authorid
  AND a_name.TotalCount >= 10
  AND a_name.NormalCount > 6
  AND r.rating IN ('4',
                   '5')
  AND b.lang = 'ru'
  AND g.genreid IN
    (SELECT mlgenrename.genreid
     FROM mlgenrename)
ORDER BY 1;

--  a_name.LastName ,
--         a_name.FirstName,
--         a_name.MiddleName;