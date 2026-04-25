.PHONY: server add edit

server:
	python3 -m http.server 8000

add:
	ruby add_book.rb

edit:
	ruby add_review.rb
