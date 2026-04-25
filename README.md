# Lev

Personal book tracker at [books.42.uy](https://books.42.uy). Named after Lev Tolstoi.

Single-page app — vanilla HTML/CSS/JS, no frameworks. Book data lives in `db.json`.

## Usage

```bash
# Add a book (fetches metadata from OpenLibrary)
ruby add_book.rb

# Add or edit a review
ruby add_review.rb

# Serve locally
python3 -m http.server 8000
```

## License

MIT
