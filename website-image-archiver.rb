# frozen_string_literal: true

require 'bundler/setup'
require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'uri'
require 'logger'
require 'set'

class WebsiteArchiver
  RETRY_ATTEMPTS = 3
  RETRY_DELAY = 5 # seconds

  class << self
    def logger
      @logger ||= Logger.new(STDOUT).tap do |log|
        log.level = Logger::INFO
        log.formatter = proc do |severity, datetime, _progname, msg|
          formatted_message = "#{datetime}: #{severity} - #{msg}\n"
          File.open('archive_log.txt', 'a') { |file| file.write(formatted_message) }
          formatted_message
        end
      end
    end

    def sanitize_filename(filename)
      filename.gsub(/[^0-9A-Za-z.-]/, '_')
    end

    def file_exists?(url, path)
      return false unless File.exist?(path)

      remote_size = URI.open(url, 'rb') { |f| f.meta['content-length'].to_i }
      local_size = File.size(path)

      remote_size == local_size
    rescue StandardError => e
      logger.error("Error checking file #{url}: #{e.message}")
      false
    end

    def download_image(url, path)
      return true if file_exists?(url, path)

      URI.open(url, 'rb') do |input|
        File.binwrite(path, input.read)
      end
      logger.info("Downloaded: #{url} to #{path}")
      true
    rescue StandardError => e
      logger.error("Error downloading image from #{url}: #{e.message}")
      false
    end

    def process_page(url, base_url)
      return [[], [], nil, nil, []] if url.start_with?('mailto:') || url.include?('/tag/')

      html = URI.open(url)
      doc = Nokogiri::HTML(html)

      links = doc.css('a').map { |link| link['href'] }.compact.uniq
      images = find_main_image(doc)

      full_links = process_links(links, base_url)
      full_images = process_images(images, base_url)

      title = doc.at_css('h1, h2, h3')&.text&.strip || 'Untitled'
      description = doc.css('p').map(&:text).join("\n\n")

      logger.info("Processed page: #{url}, Found #{full_links.size} links and #{full_images.size} images")
      [full_links, full_images, title, description, []]
    rescue StandardError => e
      logger.error("Error processing page #{url}: #{e.message}")
      [[], [], nil, nil, []]
    end

    def find_main_image(doc)
      images = []

      # Check for images in the main content area
      main_div = doc.at_css('div#main.box, div#content')
      images += main_div.css('img[src*="default"]').map { |img| img['src'] } if main_div

      # If no images found in main content, check the entire document
      images += doc.css('img[src*="default"]').map { |img| img['src'] } if images.empty?

      images.uniq
    end

    def process_links(links, base_url)
      links.map do |link|
        URI.join(base_url, link).to_s
      rescue StandardError
        nil
      end
           .compact
           .select { |link| URI.parse(link).host == URI.parse(base_url).host }
           .reject { |link| link.include?('/tag/') }
    end

    def process_images(images, base_url)
      images.map do |img|
        full_url = URI.join(base_url, img).to_s
        uri = URI.parse(full_url)
        full_url if uri.host == URI.parse(base_url).host
      rescue URI::InvalidURIError => e
        logger.warn("Invalid image URL: #{img}. Error: #{e.message}")
        nil
      end.compact
    end

    def crawl_website(start_url)
      uri = URI.parse(start_url)
      base_url = "#{uri.scheme}://#{uri.host}"
      visited = Set.new
      to_visit = [start_url]
      sections = {}

      until to_visit.empty?
        current_url = to_visit.pop
        next if visited.include?(current_url) || current_url.include?('/tag/')

        visited.add(current_url)

        logger.info("Processing: #{current_url}")
        links, images, title, description, = process_page(current_url, base_url)

        section_name = current_url.split('/').last
        sections[section_name] ||= { title:, images: [], text_content: description }
        sections[section_name][:images] += images

        new_links = links - visited.to_a - to_visit
        to_visit += new_links
        logger.info("Added #{new_links.size} new links to visit")
      end

      logger.info("Crawling complete. Processed #{visited.size} pages.")
      sections
    end

    def save_content(sections, output_dir)
      FileUtils.mkdir_p(output_dir)
      failed_downloads = []

      sections.each do |section_name, section_data|
        dir_name = File.join(output_dir, sanitize_filename(section_name))
        FileUtils.mkdir_p(dir_name)

        failed_downloads += save_images(section_data[:images], dir_name)
        save_text_content(section_data, dir_name)
      end

      log_failed_downloads(failed_downloads, output_dir)

      failed_downloads
    end

    def save_images(images, dir_name)
      failed_downloads = []

      images.each_with_index do |img_url, index|
        img_name = "#{File.basename(dir_name)}-#{index + 1}#{File.extname(URI.parse(img_url).path)}"
        file_path = File.join(dir_name, img_name)

        success = attempt_download(img_url, file_path)
        failed_downloads << [img_url, file_path] unless success
      end

      failed_downloads
    end

    def attempt_download(img_url, file_path)
      RETRY_ATTEMPTS.times do |attempt|
        return true if download_image(img_url, file_path)

        logger.warn("Download attempt #{attempt + 1} failed for #{img_url}. Retrying in #{RETRY_DELAY} seconds...")
        sleep RETRY_DELAY
      end

      false
    end

    def save_text_content(section_data, dir_name)
      text_file_path = File.join(dir_name, 'content.txt')
      File.open(text_file_path, 'w') do |file|
        file.puts section_data[:title]
        file.puts "\n"
        file.puts section_data[:text_content]
      end
      logger.info("Saved text content to #{text_file_path}")
    end

    def log_failed_downloads(failed_downloads, output_dir)
      return if failed_downloads.empty?

      failed_log_path = File.join(output_dir, 'failed_downloads.txt')
      File.open(failed_log_path, 'w') do |file|
        failed_downloads.each { |url, path| file.puts "#{url},#{path}" }
      end
      logger.warn("Some downloads failed. Check #{failed_log_path} for details.")
    end

    def retry_failed_downloads(failed_downloads)
      still_failed = []

      failed_downloads.each do |url, path|
        logger.info("Retrying download for #{url}")
        success = attempt_download(url, path)
        still_failed << [url, path] unless success
      end

      still_failed
    end

    def archive(start_url, output_dir = 'archive')
      logger.info("Starting archiving process for #{start_url}")
      sections = crawl_website(start_url)
      logger.info("Crawling complete. Found #{sections.size} sections")

      failed_downloads = save_content(sections, output_dir)

      if failed_downloads.any?
        logger.info("Retrying #{failed_downloads.size} failed downloads...")
        still_failed = retry_failed_downloads(failed_downloads)

        log_final_results(still_failed, output_dir)
      end

      logger.info("Website archiving complete! Saved to: #{output_dir}")
    end

    def log_final_results(still_failed, output_dir)
      if still_failed.any?
        logger.warn('Some downloads still failed after retries.')
        File.open(File.join(output_dir, 'failed_downloads_final.txt'), 'w') do |file|
          still_failed.each { |url, path| file.puts "#{url},#{path}" }
        end
      else
        logger.info('All failed downloads were successfully retrieved on retry.')
      end
    end
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  puts 'Script is starting...'
  start_url = 'http://loukiehoos.nl'
  WebsiteArchiver.logger.info("Script started. Archiving #{start_url}")
  WebsiteArchiver.archive(start_url)
  WebsiteArchiver.logger.info('Script finished.')
end
