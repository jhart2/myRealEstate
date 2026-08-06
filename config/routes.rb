Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resource :registration, only: %i[new create]

  root "home#index"

  resources :properties, only: %i[index show] do
    resource :favorite, only: %i[create destroy]
  end
  resources :favorites, only: :index
  resources :agents, only: %i[index show]
  resources :inquiries, only: :create
  resources :subscriptions, only: :create
  get "locations/autocomplete", to: "locations#autocomplete"
  get "travel/estimate", to: "travel#estimate"

  get "about", to: "pages#about"
  get "contact", to: "pages#contact"

  namespace :portal do
    root "dashboard#index"
    resources :properties, except: :show
    resource :profile, only: %i[edit update]
    resources :inquiries, only: %i[index show update]
  end

  namespace :admin do
    root "dashboard#index"
    resources :properties, except: :show
    resources :agents, except: :show
    resources :inquiries, only: %i[index show update]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
