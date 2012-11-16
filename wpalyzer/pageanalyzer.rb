#!/usr/bin/env ruby
#-*- mode: ruby; encoding: utf-8 -*-
# Andrés Sanoja
# UPMC - LIP6
#
#
#
# pageanalyzer
#
# Requires: Ruby 1.9.1+ (1.8.x versions won't work), rubygems 1.3.7+ and Hpricot gem v=0.8.6
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
# ISSUES:
# 1. For commandline parameters is better to escape them, e.g:
#
# pageanalyzer.rb --input-file=/my/path with/spaces -- only processes /my/path !
# pageanalyzer.rb --input-file=/my/path\ with/spaces -- results in correct behaviour
#

Encoding.default_external = Encoding::UTF_8

require 'open3'
require 'rubygems'
require 'fileutils'
require 'hpricot'
require 'uri'
require 'yaml'
require 'open-uri'
require 'sanitize'
require './lib/url_utils.rb'
require './lib/dimension.rb'
require './lib/block.rb'
require './lib/util.rb'
require './lib/point.rb'
require './lib/separator.rb'
require './lib/convex_hull.rb'
require './lib/heuristic.rb'


#global variables
$window = Dimension.new
$document = Dimension.new
$screenshot = Dimension.new
$max_weight = 0
$heuristics = []
$next_block_id = 10000
$gid = 1
$block_count = 0
$job_id = 0
$browser_id = 0
$source_file = nil
$output_file = nil
$document_area = 0.0
$debug = false
$pdoc = 5
$doc_proportion = 1
$target_path = "./"
$color = ['#1E90FF','#90EE90','#0000FF','#FF0000','#FFA500','#8B6914','#EE1CA2','#77AF4F','#A020F0','#82B5D8','','','']

def process_node(node)
	rule_used = nil
	if node['candidate'].nil?
		unless malformed?(node) or text?(node) or !valid?(node)
			$heuristics.each do |h|
				if h.parse(node)
					rule_used = h
					break 
				end
			end
		end
	else
		ind=$heuristics.collect{|a| a.name}.index(node['rule']) 
		$heuristics[ind].action = Action.new('extract',$heuristics[ind].weight)
		rule_used = $heuristics[ind]
	end
	rule_used 
end

def detect_blocks(node)
current_block = nil
sub_block_list = []
	if node.is_a? Hpricot::Elem and !undesirable_node?(node) and visible?(node)
		heuristic = process_node(node)
		if !heuristic.nil? and heuristic.action.rec == 'extract'
			current_block = Block.new 
			current_block.id = $block_count
			$block_count += 1
			current_block.add_candidate [node],heuristic
			current_block.process_path
			#TODO: verify if there are nodes that do not corresponds to a sub-block IMPLICIT BLOCKS
			if current_block.doc < $pdoc	
				unless node.children.nil? 
					node.children.each do |e|
						sub_block_list.push detect_blocks(e)
					end
					sub_block_list.flatten!
					sub_block_list.delete(nil)
					sub_block_list.each {|b| current_block.add_child b}
				end
			end
		elsif !heuristic.nil? and heuristic.action.rec == 'divide'
			#divide
			unless node.children.nil? 
					node.children.each do |e|
						sub_block_list.push detect_blocks(e)
					end
					sub_block_list.flatten!
					sub_block_list.delete(nil)
				end
			current_block = sub_block_list
		else
			current_block = sub_block_list
		end
	end
current_block
end

def detect_separators(block)
	unless block.children.nil?
		unless block.children.size==0
			block.children.each_with_index do |child,i|
				block.children[i] = detect_separators(child)
			end
		end
	end
	block = find_separators(block,:horizontal)
	block = find_separators(block,:vertical)
block
end

def find_separators(block,mode)
	if mode == :horizontal
		block_sp = block.min_y
		block_ep = block.max_y
	else
		block_sp = block.min_x
		block_ep = block.max_x
	end
	sep = [Separator.new(block_sp,block_ep)] 
	unless block.children.nil?
		i=1
		block.children.each do |child|
			child.process_path unless child.path!=[]
			if mode==:horizontal
				child_sp = child.min_y
				child_ep = child.max_y 
			else
				child_sp = child.min_x
				child_ep = child.max_x 
			end
			to_add = []
			to_del = []
			ns=sep.size
			k=0
			while k<ns
				if sep[k].contains? child,mode
					aux =sep[k].ep
					sep[k].ep = child_sp
					sep.insert(k+1,Separator.new(child_ep,aux))
					k=k+1
					ns+=1
				elsif sep[k].covered_by? child,mode
					sep[k]=nil
					sep.delete(nil)
					k=k-1
					ns-=1
				else
					if sep[k].top_crossed_by? child,mode
						sep[k].sp = child_ep
					elsif sep[k].bottom_crossed_by? child,mode
						sep[k].ep = child_sp
					end
				end
				k+=1
			end

		end
		sep = sep[1..-2]
		sep = [] if sep.nil?
		if mode == :horizontal
			block.hsep = sep
		else
			block.vsep = sep
		end
	end
	block.vsep = sep if mode == :vertical
	block.hsep = sep if mode == :horizontal
block
end


def to_xml
src = ""
src += "<?xml version=\"1.0\" encoding=\"iso-8859-1\" standalone=\"yes\" ?>\n"
src += "<XML>\n"
	src += "<Document url=\"#{escape_html($document.url)}\" Title=\"#{escape_html($document.title)}\" Version=\"#{$version}\" Pos=\"WindowWidth||PageRectLeft:#{$document.width} WindowHeight||PageRectTop:#{$document.height} ObjectRectWith:0 ObjectRectHeight:0\">\n"
		src += $root.to_xml
	src += "</Document>\n"
src += "</XML>\n"
src 
end

def help
	usage
	puts "This tool is oriented to separate web pages into segments called blocks, based on the structural and visual properties"
end

def usage
	#puts "USAGE:\nruby pageanalyzer.rb --source-file=FILE [--output-file=FILE] [--pdoc=(0..10)] [--interactive=(yes|no)] [--use-database=(yes|no) [--db-job-id=INT] [--db-browser-id=INT]] [--debug=(yes|no)] [--help]"
	puts "USAGE: ruby pageanalyzer.rb --source-file=FILE [--output-file=FILE] [--pdoc=(0..10)] [--version] [--help]"
end

#main

#parsing command-line options (TODO: add option parser)
if ARGV == []
	usage
	exit
end

ARGV.each do |op|
	$source_file = op.split("=")[1] if op[0..13] == "--source-file="
	$output_file = op.split("=")[1] if op[0..13] == "--output-file="
	$pdoc = op.split("=")[1].to_i if op[0..6] == "--pdoc="
	$interactive = op.split("=")[1]=='yes' if op[0..13]  == "--interactive="
	$use_database = op.split("=")[1]=='yes' if op[0..14] == "--use-database="
	$job_id = op.split("=")[1].to_i if op[0..11] == "--db-job-id="
	$browser_id = op.split("=")[1].to_i if op[0..15] == "--db-browser-id="
	$debug = op.split("=")[1]=='yes' if op[0..7] == "--debug="
	if op[0..6] == "--help"
		help
		exit
	end
	if op[0..9] == "--version"
		puts "SCAPE Webpage Analyzer. Version 0.9"
		puts "UPMC - LIP6"
		exit
	end
end

unless $output_file.nil?
	$target_path = $source_file.split("/")
	$target_path.delete_at($target_path.size-1)
	$target_path = $target_path.join("/")+"/"
end

doc = load($source_file,$job_id)
doc = normalize_DOM(doc)

$doc_proportion = $document_area / 10.0
$doc_rel = 10-$pdoc+1

$heuristics = []
$heuristics.push Body.new(4)	#only for body
$heuristics.push Invalids.new(3)	#skip
$heuristics.push OneChild.new(3)	#divide
$heuristics.push LayoutContainer.new(4)	#might extract
$heuristics.push IndirectContainer.new(6)	#might extract
$heuristics.push Container.new(4)	#might extract
$heuristics.push ContentContainer.new(9)	#might extract
$heuristics.push Content.new(9)	#might extract
$heuristics.push Image.new(9)	#extract
$heuristics.push DefaultDivide.new(8) #might extract
$heuristics.push DefaultExtract.new(10) #might extract

#assign weights to nodes

$root = detect_blocks(doc.at('body'))

unless $root == []
	detect_separators($root)
	$root.search_nearest_separators(:horizontal)
	$root.search_nearest_separators(:vertical)
	$root.weight_separators(:horizontal)
	$root.weight_separators(:vertical)
	#$root.merge_separators(:horizontal)
	#$root.merge_separators(:vertical)
	#$root.detect_overlapping
end

#create ouput

if $output_file.nil?
	puts to_xml
else
	File.open("#{$output_file}",'w') {|x| x.puts to_xml }
end

