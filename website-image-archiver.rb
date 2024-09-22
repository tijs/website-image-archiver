# frozen_string_literal: true

require 'bundler/setup'
require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'uri'

class WebsiteArchiver
  def self.sanitize_filename(filename)
    filename.gsub(/[^0-9A-Za-z.-]/, '_')
  end

  def self.download_image(url, path)
    URI.open(url, 'rb') do |input|
      File.open(path, 'wb') do |output|
        output.write(input.read)
      end
    end
  rescue StandardError => e
    puts "Error downloading image from #{url}: #{e.message}"
  end

  def self.extract_text_content(doc)
    title = doc.at_css('h1, h2')&.text&.strip || 'Untitled Section'
    description = doc.css('p').map(&:text).join("\n\n")
    [title, description]
  end

  def self.process_page(url, base_url)
    return [[], [], nil, nil, []] if url.start_with?('mailto:')

    html = URI.open(url)
    doc = Nokogiri::HTML(html)

    links = doc.css('a').map { |link| link['href'] }.compact.uniq
    images = doc.css('img').map { |img| img['src'] }.compact.uniq

    full_links = links.map do |link|
      URI.join(base_url, link).to_s
    rescue StandardError
      nil
    end
                      .compact
                      .select { |link| URI.parse(link).host == URI.parse(base_url).host }
    full_images = images.map do |img|
      URI.join(base_url, img).to_s
    rescue StandardError
      nil
    end
                        .compact
                        .select { |img| URI.parse(img).host == URI.parse(base_url).host }

    title, description = extract_text_content(doc)

    tags = links.select { |link| link.include?('tag') }.map { |tag| tag.split('/').last }

    [full_links, full_images, title, description, tags]
  rescue StandardError => e
    puts "Error processing page #{url}: #{e.message}"
    [[], [], nil, nil, []]
  end

  def self.crawl_website(start_url)
    uri = URI.parse(start_url)
    base_url = "#{uri.scheme}://#{uri.host}"
    visited = Set.new
    to_visit = [start_url]
    sections = {}
    all_tags = Set.new

    until to_visit.empty?
      current_url = to_visit.pop
      next if visited.include?(current_url)

      visited.add(current_url)

      puts "Processing: #{current_url}"
      links, images, title, description, tags = process_page(current_url, base_url)

      all_tags.merge(tags)

      if current_url == start_url
        sections = links.each_with_object({}) do |link, hash|
          section = link.split('/').last
          hash[link] = { title: section, images: [], text_content: nil, tags: [] }
        end
      else
        section = sections.find { |_, v| v[:title] == current_url.split('/').last }
        if section
          section[1][:images] += images
          section[1][:text_content] = { title:, description: }
          section[1][:tags] = tags
        end
      end

      to_visit += (links - visited.to_a)
    end

    [sections, all_tags.to_a]
  end

  def self.save_content(sections, all_tags, output_dir)
    FileUtils.mkdir_p(output_dir)

    sections.each_value do |section|
      next if section[:title].include?('tag') # Skip archiving tag pages

      dir_name = File.join(output_dir, sanitize_filename(section[:title]))
      FileUtils.mkdir_p(dir_name)

      # Save images
      section[:images].each_with_index do |img_url, index|
        img_name = "#{File.basename(dir_name)}-#{index + 1}.jpg"
        file_path = File.join(dir_name, img_name)
        puts "Downloading: #{img_url} to #{file_path}"
        download_image(img_url, file_path)
      end

      # Save text content
      next unless section[:text_content]

      text_file_path = File.join(dir_name, 'content.txt')
      File.open(text_file_path, 'w') do |file|
        file.puts section[:text_content][:title]
        file.puts "\n"
        file.puts section[:text_content][:description]
        file.puts "\n"
        file.puts "Tags: #{section[:tags].join(', ')}" unless section[:tags].empty?
      end
      puts "Saved text content to #{text_file_path}"
    end

    # Save all tags to a separate file
    File.open(File.join(output_dir, 'all_tags.txt'), 'w') do |file|
      file.puts all_tags.join("\n")
    end
  end

  def self.archive(start_url, output_dir = 'archive')
    sections, all_tags = crawl_website(start_url)
    save_content(sections, all_tags, output_dir)
    puts "Website archiving complete! Saved to: #{output_dir}"
  end
end

# Main execution
start_url = 'http://loukiehoos.nl'
WebsiteArchiver.archive(start_url)
