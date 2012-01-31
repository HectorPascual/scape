package eu.scape_project.pt.mapred;

import eu.scape_project.pit.invoke.CommandNotFoundException;
import java.io.IOException;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.conf.Configured;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;
import org.apache.hadoop.util.ToolRunner;

import eu.scape_project.pt.proc.FileProcessor;
import eu.scape_project.pt.util.ArgsParser;

import eu.scape_project.pit.invoke.Processor;
import eu.scape_project.pit.invoke.ToolSpecNotFoundException;

import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map.Entry;
/**
 * A command-line interaction wrapper to execute cmd-line tools with MapReduce.
 * Code based on SimpleWrapper.
 * 
 * @author Rainer Schmidt [rschmidt13]
 * @author Matthias Rella [myrho]
 */ 
public class CLIWrapper extends Configured implements org.apache.hadoop.util.Tool {

	private static Log LOG = LogFactory.getLog(CLIWrapper.class);
	
	public static class CLIMapper extends Mapper<Object, Text, Text, IntWritable> {
	    //Mapper<Text, Buffer, Text, IntWritable> {

        /**
         * The Command-Line Processor. 
         * The same for all maps.
         */
        static Processor p = null;

        /**
         * Parser for the parameters in the command-lines (records).
         */
        static ArgsParser parser = null;

        /**
         * Workaround data structure to represent Toolspec Input Specifications
         */
        static HashMap<String, HashMap> mapInputs = null;
			
        /**
         * Sets up stuff which needs to be created only once and can be used in all maps this Mapper performs.
         * 
         * For per Job there can only be one Tool and one Action selected, this stuff is the processor and the input parameters parser.
         * @param context
         */
        @Override
		public void setup( Context context ) {
	    	String tstr = context.getConfiguration().get(ArgsParser.TOOLSTRING);
	    	String astr = context.getConfiguration().get(ArgsParser.ACTIONSTRING);
            p = null;
            try {
                p = Processor.createProcessor( tstr, astr );
            } catch( ToolSpecNotFoundException e ) {
                e.printStackTrace();
            } catch (CommandNotFoundException e) {
                e.printStackTrace();
            }
	    	
            // FIXME get parameter keys (inputs) used in the toolspec action
            // preferably: HashMap<String, String> inputs = p.getInputs();
            // workaround: 
            mapInputs = getInputs(tstr, astr);

            // get the parameters (the vars in the toolspec action command)
            // if mapInputs can be retrieved and parsing of the record as a command line would work:
            parser = new ArgsParser();
            for( Entry<String, HashMap> entry: mapInputs.entrySet()) 
                parser.setOption( entry.getKey(), entry.getValue() );
            
		}

        /**
         * The map gets a key and value, the latter being a single command-line with execution parameters for pre-defined Toolspec and Action-id.
         * 
         * 1. Parse the input command-line and read parameters and arguments.
         * 2. Find input- and output-files. Input files are copied from their remote location (eg. HDFS) to a local temporary location. A local temporary location for the output-files is defined.
         * 3. Run the tool using xa-pits Processor.
         * 4. Copy output-files (if needed) from the temp. local location to the remote location which may be defined in the command-line parameter.
         * 
         * @param key 
         * @param value command-line with parameters and values for the tool
         * @param context Job context
         * @throws IOException
         * @throws InterruptedException
         */
        @Override
		public void map(Object key, Text value, Context context
	                    ) throws IOException, InterruptedException {
	    	
	    	LOG.info("MyMapper.map key:"+key.toString()+" value:"+value.toString());

            String[] args = ArgsParser.makeCLArguments( value.toString() );
            parser.parse( args );

            HashMap<String, String> mapParams = new HashMap<String, String>();
            for( String strKey : mapInputs.keySet() )
                if( parser.hasOption( strKey ) ) mapParams.put( strKey, parser.getValue(strKey) );

            // if mapInputs cannot be retrieved, the paramters could be parsed with that function:
            //HashMap<String, String> mapParams = ArgsParser.readParameters( value.toString() );

            // parse parameter values for input- and output-files
            // FIXME need distinct datatypes in Toolspec Inputs for input- and output-files to distinguish between input- and output-file-parameters
            // workaround: for now "direction" does that
            ArrayList<String> inFiles = new ArrayList<String>();
            ArrayList<String> outFiles = new ArrayList<String>();
            for( Entry<String, HashMap> entry : mapInputs.entrySet() ) {
                HashMap<String, Object> mapValues = entry.getValue();
                if( mapValues.get("datatype").equals( URI.class ) && mapValues.containsKey("direction")) {
                    String strFile = mapParams.get( entry.getKey() );
                    if( mapValues.get("direction").equals("input"))
                    {
                        inFiles.add( strFile );
                        // replace the input parameter with the temporary local location
                        mapParams.put( entry.getKey(), FileProcessor.getTempInputLocation(strFile));
                    }
                    else if( mapValues.get("direction").equals("output") )
                    {
                        outFiles.add( strFile );
                        // replace the output parameter with the temporary local location
                        mapParams.put( entry.getKey(), FileProcessor.getTempOutputLocation(strFile));
                    }
                }
            }

            // bring hdfs files to the exec-dir and use a hash of the file's full path as identifier
            // prepares input files for local processing through command line tool
	    	FileSystem hdfs = FileSystem.get(new Configuration());
	    	FileProcessor fileProcessor = new FileProcessor(inFiles.toArray(new String[0]), outFiles.toArray(new String[0]), hdfs);
	    	
	    	try {
	    		fileProcessor.resolvePrecondition();
	    	} catch(Exception e_pre) {
	    		LOG.error("Exception in preprocessing phase: " + e_pre.getMessage(), e_pre);
	    		e_pre.printStackTrace();
	    	}	    	
	    	
            // run processor
	    	// TODO use sthg. like contextObject to manage type safety (?)

	    	try {
                p.execute( mapParams );
	    	} catch(Exception e_exec) {
	    		LOG.error("Exception in execution phase: " + e_exec.getMessage(), e_exec);
	    		e_exec.printStackTrace();
	    	}	    		    		
	    	
            // TODO bring output files in exec-dir back to the locations on hdfs as defined in the parameter value
	    	try {
	    		fileProcessor.resolvePostcondition();
	    	} catch(Exception e_post) {
	    		LOG.error("Exception in postprocessing phase: " + e_post.getMessage(), e_post);
	    		e_post.printStackTrace();
	    	}
	    	
	    	
	    	/** STREAMING works but we'll integrate that later
	    	//Path inFile = new Path("hdfs://"+value.toString());
	    	//Path outFile = new Path("hdfs://"+value.toString()+".pdf");
	    	//Path fs_outFile = new Path("/home/rainer/tmp/"+inFile.getName()+".pdf");

	    	 
	    	String[] cmds = {"ps2pdf", "-", "/home/rainer/tmp"+fn+".pdf"};
	    	//Process p = new ProcessBuilder(cmds[0],cmds[1],cmds[2]).start();
	    	Process p = new ProcessBuilder(cmds[0],cmds[1],cmds[1]).start();
	    	
	    	//opening file
	    	FSDataInputStream hdfs_in = hdfs.open(inFile);
	    	FSDataOutputStream hdfs_out = hdfs.create(outFile);
	    	//FileOutputStream fs_out = new FileOutputStream(fs_outFile.toString());
	    		    	
	    	//pipe(process.getErrorStream(), System.err);
	    	
	    	OutputStream p_out = p.getOutputStream();
	    	InputStream p_in = p.getInputStream();
	    	//TODO copy outstream and send to log file
	    	
	    	byte[] buffer = new byte[1024];
	    	int bytesRead = -1;
	    	
	    	System.out.println("streaming data to process");
	    	Thread toProc = pipe(hdfs_in, new PrintStream(p_out), '>');
	    	
	    	System.out.println("streaming data to hdfs");()
	    	Thread toHdfs = pipe(p_in, new PrintStream(hdfs_out), 'h'); 
	    	
	    	//pipe(process.getErrorStream(), System.err);
	    	
	    	toProc.join();	    	
	    	
	    	*/


	    }

        /**
         * Just a workaround to get some form of representation of Toolspec Inputs.
         * Should be replaced by an appropriate method in pit.invoke.Processor.
         * 
         * @param strTool 
         * @param strAction 
         * @return 
         */
        public static HashMap<String, HashMap> getInputs( String strTool, String strAction ) {
            HashMap<String, HashMap> mapInputz = new HashMap<String,HashMap>();
            if( strTool.equals("ghostscript") && strAction.equals("gs-to-pdfa")) {
                HashMap<String, Object> mapInputParam = new HashMap<String, Object>();
                mapInputParam.put( "required", false );
                mapInputParam.put( "datatype", URI.class );
                mapInputParam.put( "direction", "input");
                mapInputz.put("input", mapInputParam);

                HashMap<String, Object> mapOutputParam = new HashMap<String, Object>();
                mapOutputParam.put( "required", false );
                mapOutputParam.put( "datatype", URI.class );
                mapOutputParam.put( "direction", "output");
                mapInputz.put("output", mapOutputParam);
            }
            else if( ArgsParser.TOOLSTRING.equals("file") && ArgsParser.ACTIONSTRING.equals("file")) {
                HashMap<String, Object> mapInputParam = new HashMap<String, Object>();
                mapInputParam.put( "required", true );
                mapInputParam.put( "datatype", URI.class );
                mapInputz.put("input", mapInputParam);
            }
            return mapInputz;
        }
	  
	}


	public static class CLIReducer extends Reducer<Text, IntWritable, Text, IntWritable> {
		
        @Override
		public void reduce(Text key, Iterable<IntWritable> values, Context context) throws IOException, InterruptedException {
			
		}
	}
	
    /**
     * Sets up, initializes and starts the Job.
     * 
     * @param args
     * @return
     * @throws Exception
     */
    @Override
	public int run(String[] args) throws Exception {

		Configuration conf = getConf();
		Job job = new Job(conf);
		
		job.setJarByClass(CLIWrapper.class);

		job.setOutputKeyClass(Text.class);
		job.setOutputValueClass(IntWritable.class);
		
		job.setMapperClass(CLIMapper.class);
	
		
		//job.setReducerClass(MyReducer.class);

		job.setInputFormatClass(PtInputFormat.class);
		//job.setOutputFormatClass(FileOutputFormat.class);
		
		//job.setOutputFormatClass(MultipleOutputFormat.class);
		
		//FileInputFormat.addInputPath(job, new Path(args[0])); ArgsParser.INFILE
		//FileOutputFormat.setOutputPath(job, new Path(args[1])); ArgsParser.OUTDIR
		FileInputFormat.addInputPath(job, new Path(conf.get(ArgsParser.INFILE)));
		String outDir = (conf.get(ArgsParser.OUTDIR) == null) ? "out/"+System.nanoTime()%10000 : conf.get(ArgsParser.OUTDIR); 
		conf.set(ArgsParser.OUTDIR, outDir);
		FileOutputFormat.setOutputPath(job, new Path(outDir) ); 
				
		//add command to job configuration
		//conf.set(TOOLSPEC, args[2]);
		
		//job.setNumReduceTasks(Integer.parseInt(args[2]));

		//FileInputFormat.setInputPaths(job, s.toString());
		//FileOutputFormat.setOutputPath(job, new Path("output"));

		//FileInputFormat.setMaxInputSplitSize(job, 1000000);

		job.waitForCompletion(true);
		return 0;
	}
	
	public static void main(String[] args) throws Exception {
		
		int res = 1;
		CLIWrapper mr = new CLIWrapper();
        Configuration conf = new Configuration();
        		
		try {
			ArgsParser pargs = new ArgsParser("i:o:t:a:p:x", args);
			//input file
			LOG.info("input: "+ pargs.getValue("i"));
			//hadoop's output 
			LOG.info("output: "+pargs.getValue("o"));
			//tool to select
			LOG.info("tool: "+pargs.getValue("t"));
            //action to select
            LOG.info("action: "+pargs.getValue("a"));
			//defined parameter list
			LOG.info("parameters: "+pargs.getValue("p"));
			
			conf.set(ArgsParser.INFILE, pargs.getValue("i"));			
			//toolMap.initialize();
			//ToolSpec tool = toolMap.get(pargs.getValue("t"));
			//if(tool != null) conf.set(ArgsParser.TOOLSTRING, tool.toString());
            conf.set(ArgsParser.TOOLSTRING, pargs.getValue("t"));
            conf.set(ArgsParser.ACTIONSTRING, pargs.getValue("a"));
	        if (pargs.hasOption("o")) conf.set(ArgsParser.OUTDIR, pargs.getValue("o"));
	        if (pargs.hasOption("p")) conf.set(ArgsParser.PARAMETERLIST, pargs.getValue("p"));

            // TODO validate input parameters (eg. look for toolspec, action, ...)
	        
            /*
			if(tool == null) {
				System.out.println("Cannot find tool: "+pargs.getValue("t"));
				System.exit(-1);
			}
             */
	        //don't run hadoop
	        if(pargs.hasOption("x")) {
	        	
	        	/*
	        	String t = System.getProperty("java.io.tmpdir");
	    		LOG.info("Using Temp. Directory:" + t);
	    		File execDir = new File(t);
	    		if(!execDir.exists()) {
	    			execDir.mkdir();
	    		}
	        	
	    		LOG.info("Is execDir a file: "+execDir.isFile() + " and a dir: "+execDir.isDirectory());
	    		File paper_ps = new File(execDir.toString()+"/paper.ps");
	    		LOG.info("Looking for this file: "+paper_ps);
	    		LOG.info("Is paper.ps a file: "+paper_ps.isFile());
	    		
	    		//LOG.info("trying ps2pdf in without args.....");
	    		String cmd = "/usr/bin/ps2pdf paper.ps paper.ps.pdf";
	    		String[] cmds = cmd.split(" ");
	    		System.out.println("cmds.length "+cmds.length);
	    		ProcessBuilder pb = new ProcessBuilder(cmds);
	    		pb.directory(execDir);
	    		Process p1 = pb.start();
	    		//LOG.info(".....");
	        	*/
	        	
	        	
	        	System.out.println("option x detected.");	        	
	        	System.exit(1);
	        }
		} catch (Exception e) {
			System.out.println("usage: CLIWrapper -i inFile [-o outFile] [-p \"parameterList\"] -t cmd");
			LOG.info(e);
			System.exit(-1);
		}
				
        try {
			LOG.info("Running MapReduce ..." );
			res = ToolRunner.run(conf, mr, args);
		} catch (Exception e) {
			e.printStackTrace();
		}
		System.exit(res);
	}		
		
}
	
	