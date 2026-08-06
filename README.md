# TT Realty

Full-featured Rails 8 real estate platform for TT Realty — searchable listings, agent profiles, favorites, inquiries, newsletter signups, and an admin console.

## Stack

- Ruby 3.4 / Rails 8.1
- Hotwire (Turbo + Stimulus)
- Tailwind CSS v4
- SQLite (development)
- Rails built-in authentication (`has_secure_password` + sessions)

## Setup

```bash
bin/setup
bin/rails db:seed
bin/dev
```

Open [http://localhost:8443](http://localhost:8443) (port 3000 is often used by other local apps; `bin/dev` defaults to 8443).

Override with `PORT=3000 bin/dev` if you want another port.

## Demo accounts

| Role  | Email                      | Password      |
|-------|----------------------------|---------------|
| Admin | admin@estate.realty        | password123   |
| Agent | catherine@estate.realty    | password123   |
| Buyer | buyer@estate.realty        | password123   |

Agents sign in to `/portal` to manage listings, inquiries, and profile experience.

## Features

- Marketing home page with hero search
- Property search/filter (intent, location, type, budget)
- Property detail pages with inquiry forms
- Agent directory and profiles
- User registration / sign-in / password reset
- Favorites for signed-in users
- Agent portal for signed-in agents (listings, inquiries, profile & years of experience)
- Newsletter subscriptions
- Admin dashboard for properties, agents, and inquiries
