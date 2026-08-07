module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def current_user
      Current.user
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path(auth: "login")
    end

    def after_authentication_url
      if (url = session.delete(:return_to_after_authenticating)).present?
        return url
      end

      if params[:modal].present? && (referer = safe_same_host_referer(exclude_auth_paths: true))
        return strip_auth_query(referer)
      end

      user = Current.user
      if user&.admin?
        admin_root_url
      elsif user&.agent? && user.agent_profile
        portal_root_url
      else
        root_url
      end
    end

    # Prefer staying on the page that opened the auth modal.
    def modal_auth_redirect_path(**query)
      if (referer = safe_same_host_referer)
        uri = URI.parse(referer)
        q = Rack::Utils.parse_nested_query(uri.query)
        query.each { |key, value| value.present? ? q[key.to_s] = value.to_s : q.delete(key.to_s) }
        uri.query = q.to_query.presence
        return [ uri.path, uri.query ].compact.join("?")
      end

      new_session_path(query.compact)
    rescue URI::InvalidURIError
      new_session_path(query.compact)
    end

    def strip_auth_query(url)
      uri = URI.parse(url)
      q = Rack::Utils.parse_nested_query(uri.query)
      %w[auth email_address].each { |key| q.delete(key) }
      uri.query = q.to_query.presence
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    def safe_same_host_referer(exclude_auth_paths: false)
      return if request.referer.blank?

      uri = URI.parse(request.referer)
      return if uri.host.present? && uri.host != request.host

      path = uri.path.to_s
      if exclude_auth_paths && path.match?(%r{\A/(session|registration|passwords)(/|\z)})
        return
      end

      request.referer
    rescue URI::InvalidURIError
      nil
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
