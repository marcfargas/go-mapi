$ErrorActionPreference='Stop'
if(-not ('Ticket569SecretCanary' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Security.Cryptography;
public static class Ticket569SecretCanary {
    static ulong Roll(string text,int offset,int length){
        ulong hash=0;unchecked{for(int i=0;i<length;i++)hash=hash*257+(uint)text[offset+i]+1;}return hash;
    }
    public static string Fingerprint(string secret){return Roll(secret,0,secret.Length).ToString("x16");}
    static bool Matches(string text,string digest,int length,string fingerprint,Stopwatch watch,int limit){
        if(length<=0)throw new ArgumentException("Invalid canary length");
        if(text.Length<length)return false;
        bool filter=!String.IsNullOrEmpty(fingerprint);
        ulong expected=filter?Convert.ToUInt64(fingerprint,16):0;
        ulong rolling=Roll(text,0,length),power=1;
        unchecked{for(int i=1;i<length;i++)power*=257;}
        using(var sha=SHA256.Create()){
            for(int i=0;i<=text.Length-length;i++){
                if((i&4095)==0 && watch.ElapsedMilliseconds>=limit)throw new IOException("Secret-canary scan exceeded its absolute elapsed-time bound");
                if(!filter || rolling==expected){
                    byte[] bytes=Encoding.UTF8.GetBytes(text.Substring(i,length));
                    string hash=BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();
                    Array.Clear(bytes,0,bytes.Length);
                    if(hash==digest)return true;
                }
                if(i<text.Length-length){unchecked{rolling=(rolling-((uint)text[i]+1)*power)*257+(uint)text[i+length]+1;}}
            }
        }
        return false;
    }
    public static bool Contains(string path,string digest,int length,string fingerprint,long maxBytes,Stopwatch watch,int limit,out long readBytes){
        byte[] bytes;
        using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)){
            long size=file.Length;
            if(size>maxBytes || size>Int32.MaxValue)throw new IOException("Secret-canary scan encountered a file or run total beyond its byte bound");
            bytes=new byte[(int)size];int read=0;
            while(read<bytes.Length){
                if(watch.ElapsedMilliseconds>=limit)throw new IOException("Secret-canary scan exceeded its absolute elapsed-time bound");
                int count=file.Read(bytes,read,bytes.Length-read);if(count==0)throw new IOException("Canary file changed during bounded read");read+=count;
            }
            if(file.Length!=size)throw new IOException("Canary file grew during bounded read");
            readBytes=read;
        }
        try{
            if(Matches(new UTF8Encoding(false,false).GetString(bytes),digest,length,fingerprint,watch,limit))return true;
            // Both byte alignments matter when a UTF-16 secret is embedded in a binary file.
            foreach(bool bigEndian in new[]{false,true})foreach(int offset in new[]{0,1}){
                if(bytes.Length>offset && Matches(new UnicodeEncoding(bigEndian,false,false).GetString(bytes,offset,bytes.Length-offset),digest,length,fingerprint,watch,limit))return true;
            }
            return false;
        }finally{Array.Clear(bytes,0,bytes.Length);}
    }
}
'@
}
