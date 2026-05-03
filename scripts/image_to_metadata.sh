# ffmpeg -r 30 -f avfoundation -i "0" -frames:v 24 out.jpg
# BOOK=$(ollama run glm-ocr Text Recognition: out.jpg)

BOOK=$(ollama run glm-ocr Text Recognition: $1)

TEMPLATE="
Extract book information into a JSON document.

Search for this information:
- Original Title
- Title
- Author
- First copyright year
- ISBN

Guidelines:
- Only extract what's requested
- Don't add any other comment or note
- Just print the JSON document
- For copyright year check copyright and not publication date
"

ollama run llama3.2:1b "$TEMPLATE <text>$BOOK</text>"
