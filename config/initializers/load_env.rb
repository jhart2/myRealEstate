# Load local .env into ENV for development/test without requiring dotenv-rails.
# Real process ENV always wins (we only set missing keys).
if defined?(Rails) && Rails.env.local?
  path = Rails.root.join(".env")
  if path.exist?
    path.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      next unless line.include?("=")

      key, value = line.split("=", 2)
      key = key.to_s.strip
      value = value.to_s.strip
      value = value.delete_prefix("'").delete_suffix("'").delete_prefix('"').delete_suffix('"')
      ENV[key] = value if key.present? && ENV[key].blank?
    end
  end
end
