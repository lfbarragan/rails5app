FROM ruby:2.3.0
MAINTAINER andres@andres.wtf

# Dependencies for rubygems
RUN apt-get update > /dev/null && apt-get install -y \
  build-essential \
  nodejs \
  postgresql-client \
  vim > /dev/null

WORKDIR /opt/webapps/suchwowapp

# Cache Gems
COPY Gemfile Gemfile.lock ./


RUN gem install bundler && \
    bundle install --jobs 20 --retry 5 --without development test

# Set Rails to run in production
ENV RAILS_ENV production
ENV RACK_ENV production
ENV SECRET_KEY_BASE "suchwowsecretman"

# Copy app files
COPY . ./

# Assets
RUN bundle exec rake assets:precompile

ENTRYPOINT ["bundle", "exec"]

CMD bundle exec unicorn --port 8080
