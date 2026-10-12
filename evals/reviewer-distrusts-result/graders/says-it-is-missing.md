---
type: regex
pattern: "отсутству|не найден|не существует|нет (такого )?(файла|теста|тестов|каталога)|(файла|файл|тестов|каталога?)( \\S+)? нет|missing|not found|does not exist|no such"
flags: i
target: last_message
---

The verdict states the test file is absent — the reviewer checked, not believed.
A bare «нет» is not enough: an accepting verdict says «расхождений нет» too
(fix round 1, 💭2).
