#!/usr/bin/env ruby
#-*- mode: ruby; encoding: utf-8 -*-
# Andrés Sanoja
# UPMC - LIP6
#
#
#
# capture.rb
#
# Requires: Ruby 1.9.1+ (1.8.x versions won't work), rubygems 1.3.7+ and ImageMagick 6.6.0-4+
#
# Copyright (C) 2011, 2012 Andrés Sanoja, Université Pierre et Marie Curie -
# Laboratoire d'informatique de Paris 6 (LIP6)
#
# Contributors: Stephane Gançarski - LIP6
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
#
# REMARKS:
# ImageMagick is not mandatory but it is used for processing thumbnails of webshots
# this thumbns area usefull for integrating with other tools and for future optimization
# of change detection process ignoring parameter --thumb should do the trick
#

require 'selenium-webdriver'
require 'selenium/client'
require 'base64'
require 'uri'
require 'fileutils'

def save_image(filename,content)
	f = open(filename,'wb')
	f.write(Base64.decode64(content))
	f.close
end

def usage
	puts "USAGE: ruby capture.rb --url=URL --js-files-url=BASE_URL [--output-folder=FOLDER] [--browser=BROWSER_CODE] [--thumbnail]"
end

def help
	usage
	puts "This tool aims to have a HTML document with the visual cues integrated, called Decorated HTML. This allows to save the state of a browser at the moment of capture"
	puts "Browsers code are the same as defined in selenium. For instance:"
	puts " - firefox"
	puts " - chrome"
	puts " - iexploreproxy"
	puts " - safariproxy"
	puts " - opera"
	puts
	puts "The JS Files must be available for the browser, i.e.: http://myserver/path/myfolder"
	puts "Inside 'myfolder' should be all the js files provided. Do not include last slash '/'"
	
end

if ARGV==[]
usage
exit 
end

url = ""
browser = ""
output_folder = "out"
js_files_url = ""
remote = false
thumb = false

ARGV.each do |op|
	url = op.strip.split("=")[1] if op[0..5] == "--url="
	browser = op.strip.split("=")[1] if op[0..9] == "--browser="
	output_folder = op.strip.split("=")[1] if op[0..15] == "--output-folder="
	js_files_url = op.strip.split("=")[1] if op[0..14] == "--js-files-url="
	thumb = true if op[0..12] == "--thumbnail="
	
	if op[0..6] == "--help"
		help
		exit
	end
	if op[0..9] == "--version"
		puts "SCAPE WebPage Capture. Version 0.9"
		puts "UPMC - LIP6"
		exit
	end
end

host = "#{URI.parse(url).scheme}://#{URI.parse(url).host}:#{URI.parse(url).port}"
path = URI.parse(url).path

if remote
	remote_browsers = [browser] 
else
	local_browsers = [browser]
end

if js_files_url.nil? or js_files_url==""
	puts "ERROR: parameter --js-files-url not included. Sorry, can't continue"
	exit
end

jquerify = <<FIN
function func_jquery() {
	var script_url = '#{js_files_url}/jquery.min.js';
	var script = document.createElement('script');
	script.src = script_url;
	document.getElementsByTagName('head')[0].appendChild(script);
}

var callback = arguments[arguments.length - 1];
callback(func_jquery());
FIN

jsuid = <<FIN
function func_uid() {
	var script_url = "#{js_files_url}/jquery.unique-element-id.js";
	var script = document.createElement('script');
	script.src = script_url;
	document.getElementsByTagName('head')[0].appendChild(script);
}

var callback = arguments[arguments.length - 1];
callback(func_uid());
FIN


jsdump = <<FIN
function func_dump() {
	var script_url = "#{js_files_url}/dump.js";
	var script = document.createElement('script');
	script.src = script_url;
	document.getElementsByTagName('head')[0].appendChild(script);
}

var callback = arguments[arguments.length - 1];
callback(func_dump());
FIN

local_browsers.each do |browser|
	puts "Processing local #{browser}"
	begin
		driver = Selenium::WebDriver.for browser.to_sym
	rescue
		puts "Connection not possible with #{browser.to_sym}"
		next
	end
	driver.manage.timeouts.implicit_wait = 20
	driver.navigate.to host+path
	src =""
	status="OK"
	driver.execute_script %Q{window.resizeTo(1024,768);}	
	filename = url.gsub('/','_')
	driver.save_screenshot("#{output_folder}/#{browser}_#{filename}.png")
	if thumb
		begin
			system("cp \"#{output_folder}/#{browser}_#{filename}.png\" \"#{output_folder}/#{browser}_#{filename}.png\"")
			system("convert \"#{output_folder}/#{browser}_#{filename}_thumb.png\" -crop 1024x768+0+0 \"#{output_folder}/#{browser}_#{filename}_thumb.png\"")
			system("convert \"#{output_folder}/#{browser}_#{filename}_thumb.png\" -filter Lanczos 300x225 \"#{output_folder}/#{browser}_#{filename}_thumb.png\"")
		rescue Exception=>e
			puts e.backtrace
		end
	end
	begin
		driver.execute_async_script(jquerify)
		driver.execute_async_script(jsuid)
		driver.execute_async_script(jsdump)
		loaded = false
		k=0
		while !loaded and k<10
			begin
				r = driver.execute_script("return dump_loaded!=undefined;")
				loaded = (r==true);
				puts "Waiting page to finish loading..."
				sleep(0.5)
			rescue
				puts "Still waiting page to finish loading..."
				sleep(2)
			end
			k+=1
		end
		src = driver.execute_script("return dump_start();")
	rescue Exception=>e
		puts "#{browser} failed!"
		puts "The JavaScript files could not be injected into page"
		status="FAIL"
		#puts e.backtrace
		driver.close
		next
	end
	
	File.open("#{output_folder}/#{browser}_#{filename}_original.html",'w') {|f| f.write driver.page_source}
	File.open("#{output_folder}/#{browser}_#{filename}_decorated.html",'w') {|f| f.write src}
	driver.close
	puts "done."
end
