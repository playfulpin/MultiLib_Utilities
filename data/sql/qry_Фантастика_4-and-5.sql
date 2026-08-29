-- 
--  Фантастика
-- rated 4 & 5
--
SELECT 
       [Books].[BookID], 
       [Books].[Title], 
       [Books].[Lang], 
       [Books].[LibRate] AS [Rate], 
       [Genres].[GenreAlias]
       
FROM   [Books],
       [Genres],
       [Genre_List]
WHERE  [Books].[Lang] = "ru"
         AND [Books].[LibRate] >= 4
         AND [Books].[BookID] = [Genre_List].[BookID]
         AND [Genres].[ParentCode] = "0.17"
         AND [Genre_List].[GenreCode] = [Genres].[GenreCode];

