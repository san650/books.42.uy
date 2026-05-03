.PHONY: server add edit review author score format lookup

server:
	python3 -m http.server 8000 -d docs

add:
	ruby scripts/add_book.rb $(filter-out $@,$(MAKECMDGOALS))

edit:
	ruby scripts/edit_book.rb

review:
	ruby scripts/add_review.rb

author:
	ruby scripts/edit_author.rb

score:
	ruby scripts/score_books.rb

format:
	ruby scripts/precommit.rb

lookup:
	@ruby scripts/lookup.rb $(filter-out $@,$(MAKECMDGOALS))

%:
	@:
