# RCNY downloader by Andrew Nicklin (@technickle)
#
# Downloads the Rules of the City of New York (RCNY) to a local folder; converts to XML
#   Overwrites files if they already exist.
#   Each rule is placed into a separate XML file.
#   Errors while not handling section content are always fatal.
#   <section_content> tag holds HTML fragment as XML CDATA.
#
# KNOWN ISSUES
#   does not handle images referenced within pages (which do exist)
#   first and last pages will have truncated <section_content>
# 
# usage: ruby rcny_download.rb [titlenode.txt URL] [local_path]
#
# How it works:
#   download the rcny master tree (titlenodes.txt) file
# 	for each item in file
#		note the title and agency
#		parse the referenced frame html files (Title1eftframe.htm) 
#		parse the nodedata parameter file (<param name="Nodedata" value="title1_tree.txt">)
#       download the notedata (title1_tree.txt)
#		for each item in the file (ignoring irrelevant lines)
#			note the chapter and subchapter
#			note the section number and section title
#			identify and download the referenced content file
#			extract the section content from HTML (clip top & bottom lines by count)
#			save everything to an XML file
#		loop
#	loop

require 'net/http'		# ruby core
require 'fileutils'		# ruby core

# load configuration
if ARGV[0].nil? or ARGV[1].nil?
	puts "usage: ruby rcny_download.rb [titlenode.txt URL] [local_path]"
end
puts Time.now.to_s + " loading configuration"
title_nodes_url = ARGV[0]
remote_working_path = title_nodes_url.dup
remote_working_path.slice!(title_nodes_url.split("/").last)
puts Time.now.to_s + " Remote working path: " + remote_working_path
local_path = ARGV[1]
if !local_path.end_with?("/")
	local_path += "/"
end
if !File.directory?(local_path)
	if File.exist?(local_path)
		puts Time.now.to_s + " Cannot create " + local_path
		puts Time.now.to_s + " File with same name exists."
		exit
	end
	FileUtils.mkdir_p(local_path)
	puts Time.now.to_s + " Created local path " + local_path
end

# class object to hold rule data
class Rcny
	attr_accessor :title_id,:agency_name,:chapter_id,:chapter_name,:subchapter_name,:section_id,:section_name,:section_content
	# output this instance content to a string of XML
	# probably an easier/smarter way to do this, but it'll work for now
	def to_xml
		result = "<rule>\n"
		result += "  <title_id>" + @title_id.to_s + "</title_id>\n"
		result += "  <agency_name>" + @agency_name.to_s + "</agency_name>\n"
		result += "  <chapter_id>" + @chapter_id.to_s + "</chapter_id>\n"
		result += "  <chapter_name>" + @chapter_name.to_s + "</chapter_name>\n"
		result += "  <subchapter_name>" + @subchapter_name.to_s + "</subchapter_name>\n"
		result += "  <section_id>" + @section_id.to_s + "</section_id>\n"
		result += "  <section_name>" + @section_name.to_s + "</section_name>\n"
		result += "  <section_content><![CDATA[" + @section_content.to_s + "]]></section_content>\n"
		result += "</rule>"
		return result
	end
	# output this instance content for a filename
	def to_filetitle
		return @title_id.to_s + "-" + @chapter_id.to_s + "-" + @section_id.to_s
	end
end

# begin the hard work!
#
# download title nodes file from supplied URL
puts Time.now.to_s + " Downloading title node file"
titles_response = Net::HTTP::get_response(URI.parse(title_nodes_url))
# check for HTTP 200 (ok) or 302 (redirection - HTTP library will follow it automatically)
case titles_response
when Net::HTTPSuccess, Net::HTTPRedirection
	# iterate through each line of the title nodes file
	rcny_temp = Rcny.new
	titles_response.body.each_line do |title_line|
		# get the array of items on each line using pipe separation
		title_items = title_line.split("|")
		rcny_temp.title_id = title_items[0].split("Title")[1]
		rcny_temp.agency_name = title_items[2].split(":")[1].strip
		puts Time.now.to_s + " Title, Agency: " + rcny_temp.title_id + ", " + rcny_temp.agency_name
		# generate the url for the title node's HTML page
		current_title_htmlpage = remote_working_path + title_items[13]
		puts Time.now.to_s + " Downloading Title " + rcny_temp.title_id + " HTML left pane"
		current_title_response = Net::HTTP::get_response(URI.parse(current_title_htmlpage))
		# check for HTTP 200 (ok) or 302 (redirection - HTTP library will follow it automatically)
		case current_title_response
		when Net::HTTPSuccess, Net::HTTPRedirection
			# get the filename for the title's nodes
			# it's on the 25th line (separated by CRFLFs)
			temp = current_title_response.body.split("\r\n")[25]
			# 3rd element (separated by quotation marks)
			current_title_sectionspage = remote_working_path + temp.split("\"")[3]
			puts Time.now.to_s + " Downloading Title " + rcny_temp.title_id + " sections list"
			current_title_sections_response = Net::HTTP::get_response(URI.parse(current_title_sectionspage))
			# check for HTTP 200 (ok) or 302 (redirection - HTTP library will follow it automatically)
			case current_title_sections_response
			when Net::HTTPSuccess, Net::HTTPRedirection
				current_title_sections_response.body.each_line do |section_line|
					# need to keep track of where we are in this file
					# it defines a tree structure, so have to recognize and hold chapter headers
					# get the array of items on each line using pipe separation
					temp = section_line.split("|")
					if temp[2].start_with?("Chapter")
						# if this is a chapter header, grab the id and name
						rcny_temp.chapter_id = temp[2].split(":")[0].split(/ /)[1]
						rcny_temp.chapter_name = temp[2].split(":")[1].strip
						rcny_temp.subchapter_name = ""
						puts Time.now.to_s + " Processing Chapter: " + rcny_temp.chapter_id + ", " + rcny_temp.chapter_name
					elsif temp[2].start_with?("Subchapter")
						# if this is a subchapter header, grab the name
						rcny_temp.subchapter_name = temp[2]
						puts Time.now.to_s + " Processing Subchapter: " + rcny_temp.subchapter_name
					elsif temp[10] == "document"
						# if this is a section header, download the referred page and extract the content
						rcny_temp.section_id = temp[0].split("-")[1]
						rcny_temp.section_name = temp[2].split(":")[1].strip
						current_section_contentpage = remote_working_path + temp[13].split("/")[1]
						puts Time.now.to_s + " Downloading Section: " + current_section_contentpage
						current_section_response = Net::HTTP::get_response(URI.parse(current_section_contentpage))
						# check for HTTP 200 (ok) or 302 (redirection - HTTP library will follow it automatically)
						case current_section_response
						when Net::HTTPSuccess, Net::HTTPRedirection
							# break up section content HTML into an array of lines
							# errors are logged and execution continues.
							contentlines = current_section_response.body.split("\r\n")
							begin
								# can ignore the first 17 items in the array
								contentlines.slice!(0,16)
								# can ignore the last 19 items in the array (TODO except first and last files)
								contentlines.slice!(-20,20)
								# also can strip out the blank lines
								contentlines.delete_if {|item| item == ""}
								# create new string just of rule content, as an HTML fragment
								rcny_temp.section_content = contentlines.to_s
								filename = rcny_temp.to_filetitle + ".xml"
								puts Time.now.to_s + " Saving " + filename
								File.open(local_path + filename, 'w') {|f| f.write(rcny_temp.to_xml)}
							rescue => thud
								# handle errors by logging them. non-fatal.
								puts Time.now.to_s + " Error analyzing section file:"
								puts Time.now.to_s + " " + thud
								puts Time.now.to_s + current_section_contentpage
							end
						else
							# handle errors by logging them. non-fatal.
							puts Time.now.to_s + " Failed to load section file:"
							puts Time.now.to_s + " HTTP ERROR" + current_section_response.code.to_s + ": "+ current_section_contentpage
						end
					end
				end
			else
				puts Time.now.to_s + " Failed to load title sections file:"
				puts Time.now.to_s + " HTTP ERROR" + current_title_sections_response.code.to_s + ": " + current_title_sectionspage
				exit
			end
		else
			puts Time.now.to_s + " Failed to load title HTML file:"
			puts Time.now.to_s + " HTTP ERROR " + current_title_response.code.to_s + ": " + current_title_htmlpage
			exit
		end
	end
else
	puts Time.now.to_s + " Failed to load title node file:"
	puts Time.now.to_s + " HTTP ERROR " + titles_response.code.to_s + ": " + title_nodes_url
	exit
end