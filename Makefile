.PHONY: server add edit review format

server:
	python3 -m http.server 8000 -d public

add:
	ruby add_book.rb $(filter-out $@,$(MAKECMDGOALS))

edit:
	ruby edit_book.rb

review:
	ruby add_review.rb

format:
	ruby precommit.rb

%:
	@:
